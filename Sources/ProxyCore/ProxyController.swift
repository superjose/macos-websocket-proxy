import Foundation
import Combine

public enum ProxyStatus: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting
}

/// Drives a single `WebSocketServer`: start/stop on demand and auto-reconnect the listener
/// (with capped exponential backoff) until the user disconnects.
@MainActor
public final class ProxyController: ObservableObject {
    @Published public var localHost: String
    @Published public var localPort: String
    @Published public var remoteHost: String
    @Published public var remotePort: String
    @Published public var status: ProxyStatus = .disconnected
    @Published public var errorMessage: String?
    @Published public private(set) var isRunning = false

    // ponytail: persist to UserDefaults.standard (same domain as AppSettings). Reopens show the
    // last successfully-connected config.
    private let defaults = UserDefaults.standard

    public init() {
        localHost = defaults.string(forKey: "localHost") ?? "127.0.0.1"
        localPort = defaults.string(forKey: "localPort") ?? "8080"
        remoteHost = defaults.string(forKey: "remoteHost") ?? ""
        remotePort = defaults.string(forKey: "remotePort") ?? "8080"
    }

    public var buttonTitle: String { isRunning ? "Disconnect" : "Connect" }

    private var server: WebSocketServer?
    private var reconnectWork: DispatchWorkItem?
    private var backoff: TimeInterval = 1

    public func toggle() { isRunning ? stop() : start() }

    public func start() {
        errorMessage = nil
        guard !localHost.isEmpty else { errorMessage = "Enter a local IP / host."; return }
        guard let lp = UInt16(localPort), lp > 0 else { errorMessage = "Local port must be 1–65535."; return }
        guard !remoteHost.isEmpty else { errorMessage = "Enter a remote IP / host."; return }
        guard let rp = UInt16(remotePort), rp > 0 else { errorMessage = "Remote port must be 1–65535."; return }

        // Valid config — remember it for next launch.
        defaults.set(localHost, forKey: "localHost")
        defaults.set(localPort, forKey: "localPort")
        defaults.set(remoteHost, forKey: "remoteHost")
        defaults.set(remotePort, forKey: "remotePort")

        isRunning = true
        backoff = 1
        status = .connecting
        startServer(localHost: localHost, localPort: lp, remoteHost: remoteHost, remotePort: rp)
    }

    public func stop() {
        isRunning = false
        reconnectWork?.cancel(); reconnectWork = nil
        server?.stop(); server = nil
        status = .disconnected
    }

    private func startServer(localHost: String, localPort: UInt16, remoteHost: String, remotePort: UInt16) {
        let s = WebSocketServer(localHost: localHost, localPort: localPort,
                                remoteHost: remoteHost, remotePort: remotePort)
        s.onStateChange = { [weak self] ready, _ in
            Task { @MainActor in self?.handle(ready: ready) }
        }
        do {
            try s.start()
            server = s
        } catch {
            // bind failed immediately; retry per auto-reconnect
            status = .reconnecting
            scheduleReconnect()
        }
    }

    private func handle(ready: Bool) {
        guard isRunning else { status = .disconnected; return }
        if ready {
            status = .connected
            backoff = 1
        } else {
            status = .reconnecting
            scheduleReconnect()
        }
    }

    private func scheduleReconnect() {
        guard isRunning else { return }
        reconnectWork?.cancel()
        let delay = backoff
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning else { return }
            self.startServer(localHost: self.localHost,
                             localPort: UInt16(self.localPort) ?? 0,
                             remoteHost: self.remoteHost,
                             remotePort: UInt16(self.remotePort) ?? 0)
        }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        backoff = min(backoff * 2, 30) // ponytail: cap at 30s
    }
}
