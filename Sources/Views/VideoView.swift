import AVFoundation
import AVKit
import SwiftUI

/// Inline video player (mp4 / mov / m4v) built on AVKit's `AVPlayerView`.
///
/// - Autoplays when shown and whenever `url` changes.
/// - Playback is paused and the player item released when the URL changes, the
///   view is removed, or the window closes, so audio never keeps playing after
///   navigating away.
/// - The player view becomes first responder so Space toggles play/pause.
///   Plain ← / → are passed up the responder chain (never used for seeking) so
///   the window-level file switching keeps working.
struct VideoView: View {
    let url: URL

    private enum Phase: Equatable {
        case loading
        case ready(URL)
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var asset: AVURLAsset?

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Color.black
                VideoPlayerSurface(asset: readyAsset)
                overlay
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            Text("← → switch files · Space play/pause")
                .font(.system(size: 12))
                .foregroundColor(Color(red: 0x9A / 255.0, green: 0x9A / 255.0, blue: 0xA2 / 255.0))
                .padding(.bottom, 4)
        }
        .background(Color(red: 0x14 / 255.0, green: 0x14 / 255.0, blue: 0x16 / 255.0))
        .task(id: url) { await load(url) }
    }

    /// The asset handed to the player only once it is known to be playable and
    /// still matches the current URL (guards against stale async results).
    private var readyAsset: AVURLAsset? {
        guard case .ready(let readyURL) = phase, readyURL == url,
              let asset, asset.url == url else { return nil }
        return asset
    }

    @ViewBuilder
    private var overlay: some View {
        switch phase {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .tint(.white)
        case .failed(let message):
            VStack(spacing: 10) {
                Image(systemName: "film")
                    .font(.system(size: 34, weight: .light))
                    .foregroundColor(Color(red: 0xA0 / 255.0, green: 0xA0 / 255.0, blue: 0xA8 / 255.0))
                Text(message)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
                Text(url.lastPathComponent)
                    .font(.system(size: 11))
                    .foregroundColor(Color(red: 0xA0 / 255.0, green: 0xA0 / 255.0, blue: 0xA8 / 255.0))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(24)
        case .ready:
            EmptyView()
        }
    }

    @MainActor
    private func load(_ target: URL) async {
        // Clearing first makes the player surface pause and drop the old item
        // immediately, before the new asset is inspected.
        phase = .loading
        asset = nil

        let unplayable = "This video format can't be played (macOS supports MP4, MOV, M4V)"

        guard FileManager.default.isReadableFile(atPath: target.path) else {
            phase = .failed("This file can't be read. It may have been moved, deleted, or you may not have permission.")
            return
        }

        let candidate = AVURLAsset(url: target)
        do {
            let (playable, tracks) = try await candidate.load(.isPlayable, .tracks)
            guard !Task.isCancelled, target == url else { return }
            let hasAV = !tracks.isEmpty
            if playable && hasAV {
                asset = candidate
                phase = .ready(target)
            } else {
                phase = .failed(unplayable)
            }
        } catch {
            guard !Task.isCancelled, target == url else { return }
            phase = .failed(unplayable)
        }
    }
}

// MARK: - AppKit bridge

/// Hosts a single long-lived `AVPlayerView` whose item is swapped as the asset changes.
private struct VideoPlayerSurface: NSViewRepresentable {
    let asset: AVURLAsset?

    final class Coordinator {
        let player = AVPlayer()
        var currentAsset: AVURLAsset?
        /// Set when an item arrives before the view is in a window; played on entry.
        var pendingAutoplay = false

        init() {
            player.actionAtItemEnd = .pause
        }

        func show(_ asset: AVURLAsset?, in view: VideoPlayerNSView) {
            guard asset !== currentAsset else { return }
            player.pause()
            currentAsset = asset
            if let asset {
                player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
                if view.window != nil { player.play() } else { pendingAutoplay = true }
                view.claimFocus()
            } else {
                pendingAutoplay = false
                player.replaceCurrentItem(with: nil)
            }
        }

        func tearDown() {
            player.pause()
            player.replaceCurrentItem(with: nil)
            currentAsset = nil
            pendingAutoplay = false
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> VideoPlayerNSView {
        let view = VideoPlayerNSView()
        view.player = context.coordinator.player
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        view.videoGravity = .resizeAspect
        view.allowsPictureInPicturePlayback = false
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        let coordinator = context.coordinator
        view.onLeaveWindow = { [weak coordinator] in coordinator?.player.pause() }
        view.onEnterWindow = { [weak coordinator] in
            guard let coordinator, coordinator.pendingAutoplay, coordinator.currentAsset != nil else { return }
            coordinator.pendingAutoplay = false
            coordinator.player.play()
        }
        coordinator.show(asset, in: view)
        return view
    }

    func updateNSView(_ nsView: VideoPlayerNSView, context: Context) {
        context.coordinator.show(asset, in: nsView)
    }

    static func dismantleNSView(_ nsView: VideoPlayerNSView, coordinator: Coordinator) {
        coordinator.tearDown()
        nsView.onLeaveWindow = nil
        nsView.onEnterWindow = nil
        nsView.player = nil
    }
}

/// `AVPlayerView` that takes focus for Space play/pause, pauses when removed from
/// its window, and leaves unmodified ← / → to the window for file switching.
final class VideoPlayerNSView: AVPlayerView {
    var onLeaveWindow: (() -> Void)?
    var onEnterWindow: (() -> Void)?
    private var focusClaimPending = false

    override var acceptsFirstResponder: Bool { true }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { onLeaveWindow?() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            onEnterWindow?()
            claimFocus()
        }
    }

    /// Become first responder on the next run-loop turn (after SwiftUI layout settles).
    func claimFocus() {
        guard !focusClaimPending else { return }
        focusClaimPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.focusClaimPending = false
            guard let window = self.window, window.firstResponder !== self else { return }
            // Don't steal focus from a text field the user is typing in.
            if let text = window.firstResponder as? NSText, text.isEditable { return }
            window.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let isLeftRight = event.keyCode == 123 || event.keyCode == 124
        if isLeftRight && modifiers.isEmpty {
            // Let the window-level handler switch files instead of frame-stepping.
            nextResponder?.keyDown(with: event)
            return
        }
        super.keyDown(with: event)
    }
}
