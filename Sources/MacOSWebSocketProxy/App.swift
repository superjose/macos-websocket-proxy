import AppKit
import SwiftUI
import Combine
import ProxyCore

@main
struct ProxyApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

/// AppKit shell: owns the proxy state, settings, menu-bar item, global hotkey, and windows.
/// SwiftUI is used only for the hosted form views (ContentView / SettingsView).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let proxy = ProxyController()
    let settings = AppSettings()
    let menuBar = MenuBarController()
    let hotkey = GlobalHotkey()

    private var main: NSWindow?
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    // Set the activation policy early to avoid Dock flicker at launch.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(settings.showInDock ? .regular : .accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        wire()
        applyAllSettings()
        showMainWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    // MARK: wiring

    private func wire() {
        menuBar.actions = MenuBarController.Actions(
            statusText: { [weak self] in self?.proxy.status.text ?? "" },
            upstreamText: { [weak self] in self?.proxy.upstreamStatus.text ?? "" },
            statusSymbol: { [weak self] in self?.proxy.status.symbol ?? "" },
            connectTitle: { [weak self] in self?.proxy.buttonTitle ?? "Connect" },
            onToggleConnection: { [weak self] in self?.proxy.toggle() },
            onShowWindow: { [weak self] in self?.showMainWindow() },
            onShowSettings: { [weak self] in self?.showSettingsWindow() },
            onQuit: { NSApp.terminate(nil) }
        )
        hotkey.onTrigger = { [weak self] in self?.showMainWindow() }

        // objectWillChange covers every @Published property: one sink per observable.
        // It fires on willSet; the async hop reads the post-set value.
        proxy.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.menuBar.refresh() } }
            .store(in: &cancellables)
        settings.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.applyAllSettings() } }
            .store(in: &cancellables)
    }

    private func applyAllSettings() {
        NSApp.setActivationPolicy(settings.showInDock ? .regular : .accessory)

        if settings.showInMenuBar { menuBar.show() } else { menuBar.hide() }

        if LoginItemService.isAvailable {
            try? LoginItemService.setEnabled(settings.launchAtLogin)
        }

        if settings.hotkeyEnabled && settings.hotkey.keyCode != 0 {
            hotkey.register(keyCode: settings.hotkey.keyCode, modifiers: settings.hotkey.modifiers)
        } else {
            hotkey.unregister()
        }

        enforceAccessibility()
        menuBar.refresh()
    }

    /// Never let the user hide every way back to the UI. If Dock + menu bar are both off
    /// and no global shortcut is set, force the menu bar back on.
    private func enforceAccessibility() {
        if !settings.showInDock && !settings.showInMenuBar && !(settings.hotkeyEnabled && settings.hotkey.keyCode != 0) {
            settings.showInMenuBar = true
        }
    }

    // MARK: windows

    func showMainWindow() {
        open(&main, title: "WebSocket Proxy", resizable: true,
             size: NSSize(width: 460, height: 340), minSize: NSSize(width: 420, height: 300)) {
            ContentView(onOpenSettings: { [weak self] in self?.showSettingsWindow() })
                .environmentObject(proxy)
        }
    }

    func showSettingsWindow() {
        open(&settingsWindow, title: "Settings") { SettingsView().environmentObject(settings) }
    }

    /// Create-once window presenter: builds + remembers the window, then just re-fronts it.
    private func open<V: View>(_ window: inout NSWindow?, title: String, resizable: Bool = false,
                               size: NSSize? = nil, minSize: NSSize? = nil,
                               @ViewBuilder view: () -> V) {
        if window == nil {
            let hosting = NSHostingController(rootView: view())
            let w = NSWindow(contentViewController: hosting)
            w.title = title
            w.styleMask = [.titled, .closable, .miniaturizable]
            if resizable { w.styleMask.insert(.resizable) }
            w.isReleasedWhenClosed = false
            w.setContentSize(size ?? hosting.view.fittingSize)
            if let minSize { w.minSize = minSize }
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: main menu
    // A non-bundled AppKit app has no main menu by default, which breaks text-edit
    // shortcuts (⌘C/⌘V/⌘A/⌘Z) and ⌘Q/⌘W. Build a minimal standard menu.

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About WebSocket Proxy",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Hide", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                                         action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All",
                        action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let winMenuItem = NSMenuItem()
        let winMenu = NSMenu(title: "Window")
        winMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winMenuItem.submenu = winMenu
        mainMenu.addItem(winMenuItem)

        NSApp.mainMenu = mainMenu
    }
}
