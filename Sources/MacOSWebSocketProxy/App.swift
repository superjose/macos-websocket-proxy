import SwiftUI
import AppKit
import ProxyCore

@main
struct ProxyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = ProxyController()

    var body: some Scene {
        WindowGroup("WebSocket Proxy", id: "main") {
            ContentView()
                .environmentObject(controller)
        }
        .defaultSize(width: 440, height: 300)

        MenuBarExtra {
            StatusMenu()
                .environmentObject(controller)
        } label: {
            Image(systemName: controller.status.symbol)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Menu-bar presence shown when the window is closed (and while open).
/// "Show Window" reopens the UI via `openWindow`.
struct StatusMenu: View {
    @EnvironmentObject var controller: ProxyController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("Status: \(controller.status.text)")
        Button("Show Window") { openWindow(id: "main") }
        Divider()
        Button(controller.buttonTitle) { controller.toggle() }
        Divider()
        Button("Quit") { NSApplication.shared.terminate(nil) }
    }
}

/// Closing the last window must NOT quit the app — it should live on in the menu bar.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
