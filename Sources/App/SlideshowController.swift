import AppKit
import Combine

/// Runs a full-screen slideshow in one viewer window: enters full screen, hides the
/// controls (shown again on mouse move, auto-hidden after 2 s) and advances on a timer.
@MainActor
final class SlideshowController {
    private weak var window: NSWindow?
    private let state: ViewerState
    private let settings: AppSettings
    private let chrome: ViewerChrome
    /// Advances to the next item; returns false when there is nothing further (end, no wrap).
    private let advance: () -> Bool

    private var slideTimer: Timer?
    private var hideTimer: Timer?
    private var mouseMonitor: Any?
    private var intervalSubscription: AnyCancellable?
    /// We entered full screen for the slideshow, so we leave it again when it stops.
    private var enteredFullScreen = false
    /// Stop was requested while the full-screen animation was still running.
    private var exitWhenFullScreenEntered = false

    init(window: NSWindow, state: ViewerState, settings: AppSettings, chrome: ViewerChrome,
         advance: @escaping () -> Bool) {
        self.window = window
        self.state = state
        self.settings = settings
        self.chrome = chrome
        self.advance = advance
    }

    var isRunning: Bool { state.isSlideshowRunning }

    func start() {
        guard !isRunning, let window else { return }
        state.isSlideshowRunning = true
        chrome.controlsVisible = false
        exitWhenFullScreenEntered = false
        if window.styleMask.contains(.fullScreen) {
            enteredFullScreen = false
        } else {
            enteredFullScreen = true
            window.toggleFullScreen(nil)
        }
        window.acceptsMouseMovedEvents = true
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            if let self, event.window === self.window { self.revealControls() }
            return event
        }
        NSCursor.setHiddenUntilMouseMoves(true)
        intervalSubscription = settings.$slideshowInterval.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.armSlideTimer() }
        }
        armSlideTimer()
    }

    /// - Parameter leaveFullScreen: false when full screen has already been left by the user.
    func stop(leaveFullScreen: Bool = true) {
        guard isRunning else { return }
        state.isSlideshowRunning = false
        chrome.controlsVisible = true
        slideTimer?.invalidate(); slideTimer = nil
        hideTimer?.invalidate(); hideTimer = nil
        intervalSubscription = nil
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        NSCursor.setHiddenUntilMouseMoves(false)
        if leaveFullScreen, enteredFullScreen, let window {
            if window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            } else {
                exitWhenFullScreenEntered = true
            }
        }
        enteredFullScreen = false
    }

    /// Call when the shown file changes (manual navigation restarts the countdown).
    func itemDidChange() {
        if isRunning { armSlideTimer() }
    }

    /// Call from `windowDidEnterFullScreen`.
    func windowDidEnterFullScreen() {
        if exitWhenFullScreenEntered {
            exitWhenFullScreenEntered = false
            window?.toggleFullScreen(nil)
        }
    }

    private func armSlideTimer() {
        slideTimer?.invalidate()
        guard isRunning else { return }
        let interval = max(1, settings.slideshowInterval)
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        slideTimer = timer
    }

    private func tick() {
        guard isRunning else { return }
        // Don't advance while a sheet (e.g. delete confirmation) is up.
        if window?.attachedSheet != nil { armSlideTimer(); return }
        if advance() {
            armSlideTimer()
        } else {
            stop()
        }
    }

    private func revealControls() {
        guard isRunning else { return }
        if !chrome.controlsVisible { chrome.controlsVisible = true }
        hideTimer?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                self.chrome.controlsVisible = false
                NSCursor.setHiddenUntilMouseMoves(true)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hideTimer = timer
    }
}
