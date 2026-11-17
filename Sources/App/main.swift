import AppKit

// Entry point: AppKit lifecycle with SwiftUI content hosted in NSHostingView.
MainActor.assumeIsolated {
    // Headless self-tests exit here without showing any UI.
    SelfTest.runIfRequested(CommandLine.arguments)

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
    _ = delegate  // keep the (weakly referenced) delegate alive for the app's lifetime
}
