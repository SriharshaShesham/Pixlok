import AppKit

/// Builds the main menu in code. Viewer actions use nil targets so they reach the
/// key window's `ViewerWindowController` through the responder chain.
@MainActor
enum MainMenu {
    /// Tags of items the app delegate updates in `menuNeedsUpdate`.
    static let editInTag = 1001
    static let openWithTag = 1002

    static func build(delegate: AppDelegate) -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu(delegate)))
        main.addItem(submenu(fileMenu(delegate)))
        main.addItem(submenu(viewMenu()))
        main.addItem(submenu(imageMenu()))
        main.addItem(submenu(goMenu()))
        let window = windowMenu()
        main.addItem(submenu(window))
        let help = helpMenu(delegate)
        main.addItem(submenu(help))
        NSApp.windowsMenu = window
        NSApp.helpMenu = help
        return main
    }

    // MARK: - Menus

    private static func appMenu(_ delegate: AppDelegate) -> NSMenu {
        let name = "Picsl"
        let m = NSMenu(title: name)
        m.addItem(item("About \(name)", #selector(AppDelegate.showAbout(_:)), target: delegate))
        m.addItem(.separator())
        m.addItem(item("Settings…", #selector(AppDelegate.showSettings(_:)), ",", target: delegate))
        m.addItem(.separator())
        let services = NSMenu(title: "Services")
        NSApp.servicesMenu = services
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        m.addItem(servicesItem)
        m.addItem(.separator())
        m.addItem(item("Hide \(name)", #selector(NSApplication.hide(_:)), "h"))
        m.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        m.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        m.addItem(.separator())
        m.addItem(item("Quit \(name)", #selector(NSApplication.terminate(_:)), "q"))
        return m
    }

    private static func fileMenu(_ delegate: AppDelegate) -> NSMenu {
        let m = NSMenu(title: "File")
        m.delegate = delegate
        m.addItem(item("Open…", #selector(AppDelegate.openDocument(_:)), "o", target: delegate))
        m.addItem(.separator())
        let edit = item("Edit in…", #selector(ViewerWindowController.picslOpenInPrimaryEditor(_:)), "e")
        edit.tag = editInTag
        m.addItem(edit)
        let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        openWith.tag = openWithTag
        let openWithMenu = NSMenu(title: "Open With")
        openWithMenu.delegate = delegate
        openWith.submenu = openWithMenu
        m.addItem(openWith)
        m.addItem(item("Show in Finder", #selector(ViewerWindowController.picslShowInFinder(_:)), "r", [.command, .shift]))
        m.addItem(.separator())
        m.addItem(item("Move to Trash", #selector(ViewerWindowController.picslMoveToTrash(_:)), "\u{8}"))
        m.addItem(.separator())
        m.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        return m
    }

    private static func viewMenu() -> NSMenu {
        let m = NSMenu(title: "View")
        m.addItem(item("Zoom In", #selector(ViewerWindowController.picslZoomIn(_:)), "+"))
        m.addItem(item("Zoom Out", #selector(ViewerWindowController.picslZoomOut(_:)), "-"))
        m.addItem(item("Actual Size", #selector(ViewerWindowController.picslActualSize(_:)), "0"))
        m.addItem(item("Zoom to Fit", #selector(ViewerWindowController.picslZoomToFit(_:)), "9"))
        m.addItem(.separator())
        m.addItem(item("Rotate Left", #selector(ViewerWindowController.picslRotateLeft(_:)), "l"))
        m.addItem(item("Rotate Right", #selector(ViewerWindowController.picslRotateRight(_:)), "r"))
        m.addItem(.separator())
        m.addItem(item("Show Info", #selector(ViewerWindowController.picslToggleInfo(_:)), "i"))
        m.addItem(item("Start Slideshow", #selector(ViewerWindowController.picslToggleSlideshow(_:)), "s", [.command, .shift]))
        m.addItem(.separator())
        m.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.control, .command]))
        return m
    }

    private static func imageMenu() -> NSMenu {
        let m = NSMenu(title: "Image")
        m.addItem(item("Edit Image…", #selector(ViewerWindowController.picslEditImage(_:)), "e", [.command, .shift]))
        m.addItem(item("Save Edits", #selector(ViewerWindowController.picslSaveEdits(_:)), "s"))
        m.addItem(item("Cancel Editing", #selector(ViewerWindowController.picslCancelEditing(_:))))
        m.addItem(.separator())
        m.addItem(item("Revert to Original…", #selector(ViewerWindowController.picslRevertToOriginal(_:))))
        return m
    }

    private static func goMenu() -> NSMenu {
        let m = NSMenu(title: "Go")
        // Arrow keys are handled by the viewer's key monitor first; the equivalents
        // here make the shortcuts discoverable.
        m.addItem(item("Next", #selector(ViewerWindowController.picslNext(_:)), "\u{F703}", []))
        m.addItem(item("Previous", #selector(ViewerWindowController.picslPrevious(_:)), "\u{F702}", []))
        m.addItem(.separator())
        m.addItem(item("First", #selector(ViewerWindowController.picslFirst(_:)), "\u{F729}", []))
        m.addItem(item("Last", #selector(ViewerWindowController.picslLast(_:)), "\u{F72B}", []))
        return m
    }

    private static func windowMenu() -> NSMenu {
        let m = NSMenu(title: "Window")
        m.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        m.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        m.addItem(.separator())
        m.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return m
    }

    private static func helpMenu(_ delegate: AppDelegate) -> NSMenu {
        let m = NSMenu(title: "Help")
        m.addItem(item("Keyboard Shortcuts", #selector(AppDelegate.showKeyboardShortcuts(_:)), target: delegate))
        return m
    }

    // MARK: - Helpers

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let i = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        i.submenu = menu
        return i
    }

    private static func item(_ title: String, _ action: Selector?, _ key: String = "",
                             _ mods: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = key.isEmpty ? [] : mods
        i.target = target
        return i
    }
}
