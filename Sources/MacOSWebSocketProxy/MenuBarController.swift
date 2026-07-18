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
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: currentSymbol(), accessibilityDescription: "WebSocket Proxy")
        item.button?.image?.isTemplate = true
        item.menu = buildMenu()
        statusItem = item
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
        let status = menu.addItem(withTitle: "Proxy: \(actions?.statusText() ?? "—")", action: nil, keyEquivalent: "")
        status.isEnabled = false
        let upstream = menu.addItem(withTitle: "Upstream: \(actions?.upstreamText() ?? "—")", action: nil, keyEquivalent: "")
        upstream.isEnabled = false
        menu.addItem(NSMenuItem.separator())

        let connect = menu.addItem(withTitle: actions?.connectTitle() ?? "Connect",
                                   action: #selector(toggleConnection), keyEquivalent: "")
        connect.target = self
        menu.addItem(NSMenuItem.separator())

        let show = menu.addItem(withTitle: "Show Window", action: #selector(showWindow), keyEquivalent: "")
        show.target = self
        let settings = menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(NSMenuItem.separator())

        let quit = menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        return menu
    }

    @objc private func toggleConnection() { actions?.onToggleConnection() }
    @objc private func showWindow() { actions?.onShowWindow() }
    @objc private func showSettings() { actions?.onShowSettings() }
    @objc private func quit() { actions?.onQuit() }
}
