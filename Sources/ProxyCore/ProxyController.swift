import Foundation
import Combine
import Network

public enum ProxyStatus: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting
}

/// Health of the remote WS server: real proxied connections are ground truth,
/// with a TCP probe filling the gaps when nothing is live.
public enum UpstreamStatus: Equatable {
    case off          // proxy not running
    case waiting      // no live upstream right now; probe re-verifies within seconds
    case connected    // upstream confirmed reachable (live session or probe)
    case unreachable  // last upstream attempt failed
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
    @Published public var upstreamStatus: UpstreamStatus = .off
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
        upstreamStatus = .waiting
        startServer(localHost: localHost, localPort: lp, remoteHost: remoteHost, remotePort: rp)
        startProbing()
    }

    public func stop() {
        isRunning = false
        reconnectWork?.cancel(); reconnectWork = nil
        server?.stop(); server = nil
        stopProbing()
        liveUpstreams = 0
        status = .disconnected
        upstreamStatus = .off
    }

    private func startServer(localHost: String, localPort: UInt16, remoteHost: String, remotePort: UInt16) {
        let s = WebSocketServer(localHost: localHost, localPort: localPort,
                                remoteHost: remoteHost, remotePort: remotePort)
        s.onStateChange = { [weak self] ready, _ in
            Task { @MainActor in self?.handle(ready: ready) }
        }
        s.onUpstreamState = { [weak self] event in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                switch event {
                case .some(true):   // upstream opened: real traffic is ground truth
                    self.finishProbe()
                    self.liveUpstreams += 1
                    self.upstreamStatus = .connected
                case .some(false):  // open attempt failed
                    self.upstreamStatus = .unreachable
                case .none:         // established upstream dropped; probe re-verifies
                    self.liveUpstreams = max(0, self.liveUpstreams - 1)
                    if self.liveUpstreams == 0 { self.upstreamStatus = .waiting }
                }
            }
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

    // MARK: upstream probe
    // Raw TCP connect every 5s (not a synthetic WS handshake — real servers may reject a
    // bare handshake while real clients work, which was the false-positive source).
    // A probe failure only downgrades the badge when no real session is live, so a flaky
    // probe can never override actual proxied traffic.

    private var liveUpstreams = 0
    private var probeTimer: Timer?
    private var probeConn: NWConnection?
    private var probeTimeout: DispatchWorkItem?

    private func startProbing() {
        stopProbing()
        probeUpstream()
        probeTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.probeUpstream() }
        }
    }

    private func stopProbing() {
        probeTimer?.invalidate(); probeTimer = nil
        finishProbe()
    }

    private func finishProbe() {
        probeTimeout?.cancel(); probeTimeout = nil
        probeConn?.cancel(); probeConn = nil
    }

    private func probeFailed() {
        if liveUpstreams == 0 { upstreamStatus = .unreachable }
        finishProbe()
    }

    private func probeUpstream() {
        guard isRunning, probeConn == nil,
              let rp = UInt16(remotePort), let port = NWEndpoint.Port(rawValue: rp) else { return }
        let conn = NWConnection(host: NWEndpoint.Host(remoteHost), port: port, using: .tcp)
        probeConn = conn
        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.probeConn === conn else { return }
                switch state {
                case .ready:
                    self.upstreamStatus = .connected
                    self.finishProbe()
                case .failed:
                    self.probeFailed()
                default: break
                }
            }
        }
        conn.start(queue: .main)
        // ponytail: 3s cap; a black-holed host never reaches .failed on its own quickly.
        let timeout = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.probeConn === conn else { return }
                self.probeFailed()
            }
        }
        probeTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: timeout)
    }
}
