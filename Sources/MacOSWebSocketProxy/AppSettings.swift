import AppKit
import Combine
import Carbon.HIToolbox

/// A captured global shortcut (Carbon keycode + Carbon modifier flags + a display string).
struct Hotkey: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var display: String
}

/// Persisted user preferences (UserDefaults). The app shell subscribes to changes and
/// applies them; this type only stores + publishes.
final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var showInDock: Bool = AppSettings.read("showInDock", default: true) {
        didSet { defaults.set(showInDock, forKey: "showInDock") }
    }
    @Published var showInMenuBar: Bool = AppSettings.read("showInMenuBar", default: true) {
        didSet { defaults.set(showInMenuBar, forKey: "showInMenuBar") }
    }
    @Published var launchAtLogin: Bool = AppSettings.read("launchAtLogin", default: false) {
        didSet { defaults.set(launchAtLogin, forKey: "launchAtLogin") }
    }
    @Published var hotkeyEnabled: Bool = AppSettings.read("hotkeyEnabled", default: false) {
        didSet { defaults.set(hotkeyEnabled, forKey: "hotkeyEnabled") }
    }
    @Published var hotkey: Hotkey = AppSettings.readHotkey() {
        didSet { defaults.set(try? JSONEncoder().encode(hotkey), forKey: "hotkey") }
    }

    private static func read(_ key: String, default fallback: Bool) -> Bool {
        (UserDefaults.standard.object(forKey: key) as? Bool) ?? fallback
    }
    private static func readHotkey() -> Hotkey {
        if let data = UserDefaults.standard.data(forKey: "hotkey"),
           let h = try? JSONDecoder().decode(Hotkey.self, from: data) {
            return h
        }
        return Hotkey(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(cmdKey | shiftKey), display: "⌘⇧P")
    }
}
