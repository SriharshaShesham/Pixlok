import SwiftUI
import WebKit

/// SVG display via WebKit, honouring ViewerState zoom/rotation.
///
/// The SVG is shown through an `<img>` element in a small wrapper page, so scripts
/// and links inside the SVG never run, and nothing in it can navigate the view.
/// Scale 1.0 = the SVG's intrinsic size in CSS pixels (points). Unlike raster
/// images, "fit" may upscale, because vectors stay sharp.
struct SVGView: View {
    let url: URL
    @ObservedObject var state: ViewerState
    @StateObject private var model = SVGModel()

    var body: some View {
        ZStack {
            Color(red: 0x14 / 255, green: 0x14 / 255, blue: 0x16 / 255)
            if let doc = model.document, model.url == url {
                SVGWebRepresentable(document: doc, state: state, onRenderFailed: { model.markFailed(doc) })
            }
            switch model.url == url ? model.phase : .loading {
            case .loading:
                ImageLoadingIndicator()
            case .failed(let message):
                ImageMessageView(detail: message, fileName: url.lastPathComponent)
            case .idle, .loaded:
                EmptyView()
            }
        }
        .task(id: url) { await model.load(url) }
    }
}

/// A prepared wrapper page for one SVG file.
final class SVGDocument {
    let url: URL
    let html: String
    let intrinsicSize: CGSize
    init(url: URL, html: String, intrinsicSize: CGSize) {
        self.url = url
        self.html = html
        self.intrinsicSize = intrinsicSize
    }
}

@MainActor
final class SVGModel: ObservableObject {
    enum Phase: Equatable {
        case idle, loading, loaded
        case failed(String)
    }

    @Published private(set) var document: SVGDocument?
    @Published private(set) var phase: Phase = .idle
    private(set) var url: URL?

    nonisolated static let maxBytes = 64 * 1024 * 1024

    func load(_ url: URL) async {
        self.url = url
        document = nil
        phase = .loading
        let result = await Task.detached(priority: .userInitiated) { Self.prepare(url) }.value
        guard self.url == url, !Task.isCancelled else { return }
        switch result {
        case .success(let doc):
            document = doc
            phase = .loaded
        case .failure(let message):
            phase = .failed(message.text)
        }
    }

    func markFailed(_ doc: SVGDocument) {
        guard document === doc else { return }
        document = nil
        phase = .failed("The SVG could not be rendered. It may be damaged or use features WebKit doesn't support.")
    }

    struct Failure: Error { let text: String }

    nonisolated static func prepare(_ url: URL) -> Result<SVGDocument, Failure> {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .failure(Failure(text: "This file is no longer available."))
        }
        let data: Data
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            if let size = attrs[.size] as? NSNumber, size.intValue > maxBytes {
                return .failure(Failure(text: "This SVG is too large to display."))
            }
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            return .failure(Failure(text: "The file couldn't be read."))
        }
        // Compressed .svgz is not handled by <img> from a data URL without a MIME hint; plain SVG only.
        guard let size = SVGIntrinsicSize.parse(data) else {
            return .failure(Failure(text: "The file isn't a valid SVG image."))
        }
        let html = SVGPage.html(svgBase64: data.base64EncodedString(), size: size)
        return .success(SVGDocument(url: url, html: html, intrinsicSize: size))
    }
}

/// Reads width/height/viewBox from the root <svg> element.
enum SVGIntrinsicSize {
    private final class RootReader: NSObject, XMLParserDelegate {
        var attributes: [String: String]?
        var rootName: String?
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            rootName = elementName
            attributes = attributeDict
            parser.abortParsing()
        }
    }

    /// Returns nil when the data has no <svg> root element.
    static func parse(_ data: Data) -> CGSize? {
        let reader = RootReader()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        _ = parser.parse()
        guard let name = reader.rootName, name == "svg" || name.hasSuffix(":svg"),
              let attrs = reader.attributes else { return nil }

        var viewBox: CGSize?
        if let vb = attrs["viewBox"] {
            let nums = vb.split(whereSeparator: { $0 == " " || $0 == "," || $0.isNewline || $0 == "\t" })
                .compactMap { Double($0) }
            if nums.count == 4, nums[2] > 0, nums[3] > 0 { viewBox = CGSize(width: nums[2], height: nums[3]) }
        }
        var w = attrs["width"].flatMap(length)
        var h = attrs["height"].flatMap(length)
        if let vb = viewBox {
            if w == nil, let hh = h { w = hh * vb.width / vb.height }
            if h == nil, let ww = w { h = ww * vb.height / vb.width }
            if w == nil && h == nil { w = vb.width; h = vb.height }
        }
        let width = w ?? 300, height = h ?? 150
        guard width > 0, height > 0, width.isFinite, height.isFinite else { return CGSize(width: 300, height: 150) }
        return CGSize(width: width, height: height)
    }

    /// CSS length → px. Percentages and unknown units return nil.
    private static func length(_ raw: String) -> Double? {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let units: [(String, Double)] = [("px", 1), ("pt", 96.0 / 72), ("pc", 16), ("mm", 96 / 25.4),
                                         ("cm", 96 / 2.54), ("in", 96), ("em", 16), ("ex", 8)]
        for (suffix, factor) in units where s.hasSuffix(suffix) {
            return Double(s.dropLast(suffix.count)).map { $0 * factor }.flatMap { $0 > 0 ? $0 : nil }
        }
        if s.hasSuffix("%") { return nil }
        return Double(s).flatMap { $0 > 0 ? $0 : nil }
    }
}

/// Wrapper HTML page. Layout is driven from Swift through `picslApply(mode, scale, turns[, ax, ay])`;
/// `ax`/`ay` (CSS px from the viewport's top-left) anchor a zoom so that point stays put.
enum SVGPage {
    static func html(svgBase64: String, size: CGSize) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; script-src 'unsafe-inline'">
        <style>
        html,body{margin:0;padding:0;height:100%;background:#141416;}
        body{display:flex;overflow:auto;cursor:default;-webkit-user-select:none;user-select:none;}
        body.pannable{cursor:grab;} body.panning{cursor:grabbing;}
        #stage{margin:auto;flex:none;position:relative;}
        #img{position:absolute;display:block;transform-origin:50% 50%;-webkit-user-drag:none;
          background-color:#ffffff;
          background-image:linear-gradient(45deg,#e6e6e6 25%,transparent 25%),linear-gradient(-45deg,#e6e6e6 25%,transparent 25%),
            linear-gradient(45deg,transparent 75%,#e6e6e6 75%),linear-gradient(-45deg,transparent 75%,#e6e6e6 75%);
          background-size:16px 16px;background-position:0 0,0 8px,8px -8px,-8px 0;}
        </style></head><body><div id="stage"><img id="img" alt="" draggable="false"></div>
        <script>
        (function(){
          var W=\(size.width), H=\(size.height);
          var st={mode:'fit',scale:1,turns:0};
          var body=document.body, stage=document.getElementById('stage'), img=document.getElementById('img');
          function post(m){try{window.webkit.messageHandlers.picsl.postMessage(m);}catch(e){}}
          function layout(keepCenter, anchor){
            var fx=0.5, fy=0.5, r0=null;
            if(anchor){ r0=stage.getBoundingClientRect(); if(!(r0.width>0&&r0.height>0)) r0=null; }
            if(keepCenter && !r0 && body.scrollWidth>0 && body.scrollHeight>0){
              fx=(body.scrollLeft+body.clientWidth/2)/body.scrollWidth;
              fy=(body.scrollTop+body.clientHeight/2)/body.scrollHeight;
            }
            var odd=(st.turns%2)===1, rw=odd?H:W, rh=odd?W:H;
            var vw=body.clientWidth||window.innerWidth, vh=body.clientHeight||window.innerHeight;
            var fitS=Math.min(vw/rw,vh/rh);
            var s=st.mode==='fit'?fitS:st.scale;
            if(!isFinite(s)||s<=0) s=1;
            var iw=W*s, ih=H*s, sw=rw*s, sh=rh*s;
            stage.style.width=sw+'px'; stage.style.height=sh+'px';
            img.style.width=iw+'px'; img.style.height=ih+'px';
            img.style.left=((sw-iw)/2)+'px'; img.style.top=((sh-ih)/2)+'px';
            img.style.transform='rotate('+(st.turns*90)+'deg)';
            if(r0){
              var ax=(anchor.x-r0.left)/r0.width, ay=(anchor.y-r0.top)/r0.height, r1=stage.getBoundingClientRect();
              body.scrollLeft+=r1.left+ax*r1.width-anchor.x;
              body.scrollTop+=r1.top+ay*r1.height-anchor.y;
            } else if(keepCenter){
              body.scrollLeft=fx*body.scrollWidth-body.clientWidth/2;
              body.scrollTop=fy*body.scrollHeight-body.clientHeight/2;
            }
            body.classList.toggle('pannable', sw>vw+0.5||sh>vh+0.5);
            post({type:'scale',value:s,fit:(isFinite(fitS)&&fitS>0)?fitS:1});
          }
          window.picslApply=function(mode,scale,turns,ax,ay){
            st.mode=mode; st.scale=scale; st.turns=((turns%4)+4)%4;
            layout(mode!=='fit', (mode!=='fit'&&typeof ax==='number'&&typeof ay==='number')?{x:ax,y:ay}:null);
          };
          window.addEventListener('resize',function(){ layout(st.mode!=='fit'); });
          var drag=null;
          body.addEventListener('mousedown',function(e){
            if(e.button!==0) return; e.preventDefault();
            if(e.detail>=2){ post({type:'dblclick'}); drag=null; return; }
            drag={x:e.clientX,y:e.clientY}; if(body.classList.contains('pannable')) body.classList.add('panning');
          });
          window.addEventListener('mousemove',function(e){
            if(!drag) return; if(!(e.buttons&1)){drag=null; body.classList.remove('panning'); return;}
            body.scrollLeft-=e.clientX-drag.x; body.scrollTop-=e.clientY-drag.y; drag={x:e.clientX,y:e.clientY};
          });
          window.addEventListener('mouseup',function(){ drag=null; body.classList.remove('panning'); });
          document.addEventListener('contextmenu',function(e){e.preventDefault();});
          img.onload=function(){ layout(false); post({type:'loaded'}); };
          img.onerror=function(){ post({type:'error'}); };
          img.src='data:image/svg+xml;base64,\(svgBase64)';
        })();
        </script></body></html>
        """
    }
}

/// WKWebView that never takes keyboard focus (so ←/→ reach the window), shows no
/// context menu, and turns pinch / scroll into zoom requests.
final class SVGWebView: WKWebView {
    var onZoomFactor: ((CGFloat) -> Void)?
    /// Scroll zoom: factor plus the cursor position in CSS px from the view's top-left.
    var onScrollZoom: ((CGFloat, CGPoint) -> Void)?
    private let scrollTracker = ScrollZoomTracker()

    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }

    /// Ignore WebKit's file-drag registration so drops reach ViewerView's SwiftUI drop destination
    /// (otherwise a dropped file becomes a cancelled file:// navigation and nothing happens).
    override func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {}

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        menu.removeAllItems()
    }

    override func magnify(with event: NSEvent) {
        onZoomFactor?(1 + event.magnification)
    }

    override func smartMagnify(with event: NSEvent) {
        // Handled as double-click from the page; ignore WebKit's own smart zoom.
    }

    override func scrollWheel(with event: NSEvent) {
        switch scrollTracker.action(for: event, zoomsByDefault: AppSettings.shared.scrollWheelZooms) {
        case .pan:
            super.scrollWheel(with: event)
        case .ignore:
            break
        case .zoom(let factor):
            let p = convert(event.locationInWindow, from: nil)
            let y = isFlipped ? p.y : bounds.height - p.y
            onScrollZoom?(factor, CGPoint(x: p.x, y: y))
        }
    }
}

struct SVGWebRepresentable: NSViewRepresentable {
    let document: SVGDocument
    @ObservedObject var state: ViewerState
    let onRenderFailed: () -> Void

    /// Weak proxy so WKUserContentController does not retain the coordinator.
    final class MessageProxy: NSObject, WKScriptMessageHandler {
        weak var target: Coordinator?
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            target?.handle(message.body)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var state: ViewerState?
        var onRenderFailed: (() -> Void)?
        weak var webView: SVGWebView?
        var loadedDocument: SVGDocument?
        var pageReady = false
        var appliedZoom: ZoomMode?
        var appliedTurns: Int?
        var reportedScale: CGFloat = 1
        /// Fit scale last reported by the page.
        var fitScale: CGFloat = 1
        /// Cursor anchor (CSS px, top-left origin) for the next scale apply.
        var pendingAnchor: CGPoint?

        @MainActor
        func handle(_ body: Any) {
            guard let dict = body as? [String: Any], let type = dict["type"] as? String else { return }
            switch type {
            case "scale":
                if let v = (dict["value"] as? NSNumber)?.doubleValue {
                    reportedScale = CGFloat(v)
                    if let f = (dict["fit"] as? NSNumber)?.doubleValue, f > 0, f.isFinite { fitScale = CGFloat(f) }
                    if let state, abs(state.effectiveScale - reportedScale) > 0.0001 { state.effectiveScale = reportedScale }
                }
            case "loaded":
                pageReady = true
                webView?.alphaValue = 1
                apply(force: true)
            case "error":
                onRenderFailed?()
            case "dblclick":
                guard let state else { return }
                if state.zoom == .fit && abs(reportedScale - 1) > 0.001 { state.zoom = .scale(1) } else { state.zoom = .fit }
            default:
                break
            }
        }

        /// Scale the next zoom step starts from: the requested scale (avoids racing the page's
        /// asynchronous "scale" reports during fast gestures), or the reported one in fit mode.
        @MainActor
        private var baseScale: CGFloat {
            if let state, case .scale(let s) = state.zoom { return s }
            return reportedScale
        }

        @MainActor
        func scrollZoom(by factor: CGFloat, anchor: CGPoint) {
            guard let state, pageReady else { return }
            guard let target = ScrollZoomMath.target(
                current: baseScale, factor: factor, fit: fitScale, isFit: state.zoom == .fit,
                minScale: ViewerState.zoomSteps.first ?? 0.05,
                maxScale: ViewerState.zoomSteps.last ?? 16) else { return }
            switch target {
            case .fit:
                pendingAnchor = nil
                state.zoom = .fit
            case .scale(let s):
                reportedScale = s
                pendingAnchor = anchor
                state.zoom = .scale(s)
            }
        }

        @MainActor
        func zoom(by factor: CGFloat) {
            guard let state, pageReady else { return }
            let s = min(max(baseScale * factor, 0.01), 64)
            reportedScale = s
            pendingAnchor = nil
            state.zoom = .scale(s)
        }

        @MainActor
        func apply(force: Bool = false) {
            guard let state, let webView, pageReady else { return }
            let turns = ((state.rotationQuarterTurns % 4) + 4) % 4
            guard force || appliedZoom != state.zoom || appliedTurns != turns else { return }
            // Only anchor a pure zoom step (not a rotation, reload, or forced re-layout).
            let anchor = (force || appliedTurns != turns) ? nil : pendingAnchor
            pendingAnchor = nil
            appliedZoom = state.zoom
            appliedTurns = turns
            let js: String
            switch state.zoom {
            case .fit: js = "window.picslApply&&picslApply('fit',1,\(turns))"
            case .scale(let s):
                if let a = anchor, a.x.isFinite, a.y.isFinite {
                    js = "window.picslApply&&picslApply('scale',\(Double(s)),\(turns),\(Double(a.x)),\(Double(a.y)))"
                } else {
                    js = "window.picslApply&&picslApply('scale',\(Double(s)),\(turns))"
                }
            }
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            // Only our own loadHTMLString (about:blank) is allowed; links, forms, redirects are blocked.
            let scheme = navigationAction.request.url?.scheme?.lowercased()
            let allowed = navigationAction.navigationType == .other && (scheme == "about" || scheme == nil)
            decisionHandler(allowed ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            MainActor.assumeIsolated { onRenderFailed?() }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            MainActor.assumeIsolated { onRenderFailed?() }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            MainActor.assumeIsolated { onRenderFailed?() }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SVGWebView {
        let config = WKWebViewConfiguration()
        let proxy = MessageProxy()
        proxy.target = context.coordinator
        config.userContentController.add(proxy, name: "picsl")
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.suppressesIncrementalRendering = true
        config.websiteDataStore = .nonPersistent()

        let webView = SVGWebView(frame: .zero, configuration: config)
        webView.unregisterDraggedTypes()
        webView.navigationDelegate = context.coordinator
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        webView.underPageBackgroundColor = NSColor(srgbRed: 0x14 / 255, green: 0x14 / 255, blue: 0x16 / 255, alpha: 1)
        webView.alphaValue = 0 // until the page reports the SVG loaded (avoids a white flash)
        webView.setAccessibilityLabel(document.url.lastPathComponent)
        let coordinator = context.coordinator
        webView.onZoomFactor = { [weak coordinator] factor in
            MainActor.assumeIsolated { coordinator?.zoom(by: factor) }
        }
        webView.onScrollZoom = { [weak coordinator] factor, anchor in
            MainActor.assumeIsolated { coordinator?.scrollZoom(by: factor, anchor: anchor) }
        }
        coordinator.webView = webView
        return webView
    }

    func updateNSView(_ webView: SVGWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.state = state
        coordinator.onRenderFailed = onRenderFailed
        if coordinator.loadedDocument !== document {
            coordinator.loadedDocument = document
            coordinator.pageReady = false
            coordinator.appliedZoom = nil
            coordinator.appliedTurns = nil
            webView.alphaValue = 0
            webView.loadHTMLString(document.html, baseURL: nil)
            return
        }
        coordinator.apply()
    }

    static func dismantleNSView(_ webView: SVGWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.onZoomFactor = nil
        webView.onScrollZoom = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "picsl")
    }
}
