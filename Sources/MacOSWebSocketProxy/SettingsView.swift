import SwiftUI
import Carbon.HIToolbox

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @State private var showHideWarning = false

    private var canHideEverything: Bool { settings.hotkeyEnabled && settings.hotkey.keyCode != 0 }

    var body: some View {
        Form {
            Section("General") {
                Toggle("Show in Dock", isOn: dockBinding)
                Toggle("Show in menu bar", isOn: menuBarBinding)
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                    .disabled(!LoginItemService.isAvailable)
                if !LoginItemService.isAvailable {
                    Text("Build and run as a .app (./build-app.sh) to enable launch at login.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Global Shortcut") {
                Toggle("Enable global shortcut", isOn: $settings.hotkeyEnabled)
                HotkeyRecorder()
                    .disabled(!settings.hotkeyEnabled)
                Text("Brings the window to the front from anywhere. Required if you hide both the Dock and the menu bar.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if showHideWarning {
                Text("Keep either the Dock or the menu bar visible — or set a global shortcut — otherwise the app can't be brought back up.")
                    .font(.caption).foregroundColor(.orange)
            }
        }
        .padding(20)
        .frame(minWidth: 420, idealWidth: 460)
    }

    // Block hiding the menu bar when there'd be no way back.
    private var menuBarBinding: Binding<Bool> {
        Binding(get: { settings.showInMenuBar }) { newVal in
            if !newVal && !settings.showInDock && !canHideEverything {
                showHideWarning = true
            } else {
                showHideWarning = false
                settings.showInMenuBar = newVal
            }
        }
    }

    private var dockBinding: Binding<Bool> {
        Binding(get: { settings.showInDock }) { newVal in
            if !newVal && !settings.showInMenuBar && !canHideEverything {
                showHideWarning = true
            } else {
                showHideWarning = false
                settings.showInDock = newVal
            }
        }
    }
}

/// Captures the next key combination via an in-app NSEvent monitor. Lives in a stable
/// ObservableObject so the monitor's closures can mutate state across SwiftUI rebuilds.
private final class Recorder: ObservableObject {
    @Published var recording = false
    private var monitor: Any?
    weak var settings: AppSettings?

    func start() {
        guard !recording else { return }
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == UInt16(kVK_Escape) { self.stop(); return nil }
            let mods = carbonModifiers(event.modifierFlags)
            guard mods != 0 else { return event } // require at least one modifier
            self.settings?.hotkey = Hotkey(keyCode: UInt32(event.keyCode), modifiers: mods, display: describeShortcut(event))
            self.stop()
            return nil
        }
    }

    func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }
}

private struct HotkeyRecorder: View {
    @EnvironmentObject var settings: AppSettings
    @StateObject private var rec = Recorder()

    var body: some View {
        HStack {
            Text(settings.hotkey.display)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            Spacer()
            Button(rec.recording ? "Press keys…" : "Record") {
                rec.recording ? rec.stop() : rec.start()
            }
        }
        .onAppear { rec.settings = settings }
    }
}
