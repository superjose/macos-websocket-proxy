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
            statusSymbol: { [weak self] in self?.proxy.status.symbol ?? "" },
            connectTitle: { [weak self] in self?.proxy.buttonTitle ?? "Connect" },
            onToggleConnection: { [weak self] in self?.proxy.toggle() },
            onShowWindow: { [weak self] in self?.showMainWindow() },
            onShowSettings: { [weak self] in self?.showSettingsWindow() },
            onQuit: { NSApp.terminate(nil) }
        )
        hotkey.onTrigger = { [weak self] in self?.showMainWindow() }

        proxy.$status
            .sink { [weak self] _ in DispatchQueue.main.async { self?.menuBar.refresh() } }
            .store(in: &cancellables)

        let apply: (Any?) -> Void = { [weak self] _ in DispatchQueue.main.async { self?.applyAllSettings() } }
        settings.$showInDock.sink(receiveValue: apply).store(in: &cancellables)
        settings.$showInMenuBar.sink(receiveValue: apply).store(in: &cancellables)
        settings.$launchAtLogin.sink(receiveValue: apply).store(in: &cancellables)
        settings.$hotkeyEnabled.sink(receiveValue: apply).store(in: &cancellables)
        settings.$hotkey.sink(receiveValue: apply).store(in: &cancellables)
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
        if main == nil {
            let view = ContentView(onOpenSettings: { [weak self] in self?.showSettingsWindow() })
                .environmentObject(proxy)
            let hosting = NSHostingController(rootView: view)
            let w = NSWindow(contentViewController: hosting)
            w.title = "WebSocket Proxy"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 460, height: 340))
            w.minSize = NSSize(width: 420, height: 300)
            w.center()
            main = w
        }
        main?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showSettingsWindow() {
        if settingsWindow == nil {
            let view = SettingsView().environmentObject(settings)
            let hosting = NSHostingController(rootView: view)
            let w = NSWindow(contentViewController: hosting)
            w.title = "Settings"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.setContentSize(hosting.view.fittingSize)
            w.center()
            settingsWindow = w
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
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
