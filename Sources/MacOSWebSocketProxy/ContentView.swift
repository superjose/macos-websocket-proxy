import SwiftUI
import ProxyCore

extension ProxyStatus {
    var text: String {
        switch self {
        case .disconnected:  return "Disconnected"
        case .connecting:    return "Connecting…"
        case .connected:     return "Connected"
        case .reconnecting:  return "Reconnecting…"
        }
    }
    var color: Color {
        switch self {
        case .disconnected:            return .secondary
        case .connecting, .reconnecting: return .orange
        case .connected:               return .green
        }
    }
    var symbol: String {
        switch self {
        case .disconnected:            return "arrow.left.arrow.right.circle"
        case .connecting, .reconnecting: return "arrow.triangle.2.circlepath.circle"
        case .connected:               return "arrow.left.arrow.right.circle.fill"
        }
    }
}

struct ContentView: View {
    var onOpenSettings: () -> Void = {}
    @EnvironmentObject var controller: ProxyController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Form {
                Section("Local") {
                    TextField("IP / Host", text: $controller.localHost)
                    TextField("Port", text: $controller.localPort)
                }
                Section("Remote") {
                    TextField("IP / Host", text: $controller.remoteHost, prompt: Text("e.g. 10.211.55.3"))
                    TextField("Port", text: $controller.remotePort)
                }
            }

            Text("ws://\(controller.localHost):\(controller.localPort)  →  ws://\(controller.remoteHost.isEmpty ? "host" : controller.remoteHost):\(controller.remotePort)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let err = controller.errorMessage {
                Text(err).font(.caption).foregroundColor(.red)
            }

            HStack(spacing: 12) {
                Button(controller.buttonTitle) { controller.toggle() }
                    .buttonStyle(.borderedProminent)
                Button("Settings…") { onOpenSettings() }
                Spacer()
                statusBadge
            }
        }
        .padding(20)
        .frame(minWidth: 400, idealWidth: 440)
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            Circle().fill(controller.status.color).frame(width: 10, height: 10)
            Text(controller.status.text).font(.caption).foregroundStyle(.secondary)
        }
    }
}
