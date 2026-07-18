import AppKit

/// Owns the menu-bar status item. Show/hide is live (unlike SwiftUI's MenuBarExtra),
/// which the "hide from menu bar" setting needs.
final class MenuBarController: NSObject {
    struct Actions {
        var statusText: () -> String
        var upstreamText: () -> String
        var statusSymbol: () -> String
        var connectTitle: () -> String
        var onToggleConnection: () -> Void
        var onShowWindow: () -> Void
        var onShowSettings: () -> Void
        var onQuit: () -> Void
    }

    var actions: Actions?
    private var statusItem: NSStatusItem?

    func show() {
        guard statusItem == nil else { refresh(); return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        refresh()
    }

    func hide() {
        guard let statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    func refresh() {
        guard let statusItem else { return }
        statusItem.button?.image = NSImage(systemSymbolName: currentSymbol(), accessibilityDescription: "WebSocket Proxy")
        statusItem.button?.image?.isTemplate = true
        statusItem.menu = buildMenu()
    }

    private func currentSymbol() -> String { actions?.statusSymbol() ?? "arrow.left.arrow.right.circle" }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Proxy: \(actions?.statusText() ?? "—")"))
        menu.addItem(item("Upstream: \(actions?.upstreamText() ?? "—")"))
        menu.addItem(.separator())
        menu.addItem(item(actions?.connectTitle() ?? "Connect", #selector(toggleConnection)))
        menu.addItem(.separator())
        menu.addItem(item("Show Window", #selector(showWindow)))
        menu.addItem(item("Settings…", #selector(showSettings), ","))
        menu.addItem(.separator())
        menu.addItem(item("Quit", #selector(quit), "q"))
        return menu
    }

    /// One-line menu item: no action = disabled info line, otherwise wired to this controller.
    private func item(_ title: String, _ action: Selector? = nil, _ key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        i.isEnabled = action != nil
        return i
    }

    @objc private func toggleConnection() { actions?.onToggleConnection() }
    @objc private func showWindow() { actions?.onShowWindow() }
    @objc private func showSettings() { actions?.onShowSettings() }
    @objc private func quit() { actions?.onQuit() }
}
