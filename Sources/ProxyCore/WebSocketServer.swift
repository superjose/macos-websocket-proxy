import Foundation
import Network

/// Listens on `localHost:localPort` and, for each incoming WebSocket client, bridges it
/// to a fresh upstream WebSocket at `remoteHost:remotePort`. Mirrors ws-proxy.ts:
/// upstream must open before the client is upgraded; otherwise the client gets HTTP 502.
final class WebSocketServer {
    private var listener: NWListener?
    private var sessions: [ProxySession] = []
    let localHost: String
    let localPort: UInt16
    let remoteHost: String
    let remotePort: UInt16
    private let queue = DispatchQueue(label: "wsproxy.server", qos: .userInitiated)

    /// `(true, nil)` when the listener is ready; `(false, error?)` when stopped or failed.
    var onStateChange: ((Bool, Error?) -> Void)?

    /// `true` when a session's upstream WS opens; `false` when an upstream open attempt fails;
    /// `nil` when an established upstream drops (state unknown, probe will re-verify).
    var onUpstreamState: ((Bool?) -> Void)?

    init(localHost: String, localPort: UInt16, remoteHost: String, remotePort: UInt16) {
        self.localHost = localHost
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
    }

    func start() throws {
        stop()
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(localHost),
            port: NWEndpoint.Port(rawValue: localPort)!
        )
        let l = try NWListener(using: params)
        l.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:            self?.onStateChange?(true, nil)
            case .failed(let err):  self?.onStateChange?(false, err)
            case .cancelled:        self?.onStateChange?(false, nil)
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        l.start(queue: queue)
        listener = l
    }

    func stop() {
        listener?.cancel()
        listener = nil
        let toStop = sessions
        sessions.removeAll()
        toStop.forEach { $0.teardown() }
    }

    private func accept(_ client: NWConnection) {
        client.start(queue: queue)
        let session = ProxySession(client: client,
                                   remoteHost: remoteHost,
                                   remotePort: remotePort,
                                   queue: queue)
        session.onUpstreamState = { [weak self] up in self?.onUpstreamState?(up) }
        session.onTeardown = { [weak self] s in self?.remove(session: s) }
        sessions.append(session)
        session.run()
    }

    private func remove(session: ProxySession) {
        sessions.removeAll { $0 === session }
    }
}

/// One bridged connection: a raw-TCP server-side client leg (hand-rolled WS framing)
/// and an upstream leg driven by `URLSessionWebSocketTask`.
private final class ProxySession {
    let client: NWConnection
    let queue: DispatchQueue
    private let remoteURL: URL
    private let delegate = UpstreamDelegate()

    private var inbound = Data() // ponytail: unbounded; fine for a local proxy
    private var upgraded = false
    private var upstreamOpen = false
    private var closed = false
    private var gateTimer: DispatchWorkItem?
    private var pendingKey: String?
    private let assembler = WSMessageAssembler()

    private var upstream: URLSessionWebSocketTask?
    private var session: URLSession?

    var onTeardown: ((ProxySession) -> Void)?
    var onUpstreamState: ((Bool?) -> Void)?

    init(client: NWConnection, remoteHost: String, remotePort: UInt16, queue: DispatchQueue) {
        self.client = client
        self.queue = queue
        // ponytail: handshake path defaults to "/" — OBS/StreamerBot use root, no path field exposed.
        self.remoteURL = URL(string: "ws://\(remoteHost):\(remotePort)")!
        delegate.owner = self
    }

    func run() {
        readHandshake(Data())
    }

    // MARK: Client handshake

    private func readHandshake(_ buffer: Data) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if error != nil { self.teardown(); return }
            var buf = buffer
            if let data { buf.append(data) }

            if let range = buf.range(of: Data("\r\n\r\n".utf8)) {
                let header = buf.subdata(in: 0..<range.upperBound)
                let leftover = buf.subdata(in: range.upperBound..<buf.count)
                self.finishHandshake(headerBytes: Data(header), leftover: Data(leftover))
            } else {
                if isComplete && (data?.isEmpty ?? true) { self.teardown(); return }
                self.readHandshake(buf)
            }
        }
    }

    private func finishHandshake(headerBytes: Data, leftover: Data) {
        guard let header = String(data: headerBytes, encoding: .utf8),
              let key = wsExtractKey(httpHeader: header) else {
            respondAndClose(400, "Bad Request"); return
        }

        inbound = leftover
        pendingKey = key

        // Funnel all upstream callbacks onto `queue` so session state stays single-threaded.
        let opQueue = OperationQueue()
        opQueue.underlyingQueue = queue
        opQueue.maxConcurrentOperationCount = 1
        let urlSession = URLSession(configuration: .default, delegate: delegate, delegateQueue: opQueue)
        session = urlSession

        let task = urlSession.webSocketTask(with: remoteURL)
        upstream = task
        task.resume()

        // Gate: if the upstream doesn't open promptly, fail the client (mirrors ws-proxy's
        // upstream-open requirement). ponytail: 4s cap; unreachable hosts never report open.
        let timer = DispatchWorkItem { [weak self] in
            guard let self, !self.upstreamOpen, !self.closed else { return }
            self.onUpstreamState?(false)
            self.respondAndClose(502, "Bad Gateway")
        }
        gateTimer = timer
        queue.asyncAfter(deadline: .now() + 4, execute: timer)
    }

    // MARK: Upstream lifecycle (called on `queue` via the delegate queue)

    fileprivate func upstreamDidOpen() {
        guard !closed, !upstreamOpen else { return }
        upstreamOpen = true
        gateTimer?.cancel(); gateTimer = nil
        onUpstreamState?(true)
        upgradeClient()
    }

    fileprivate func upstreamDidFail() {
        guard !closed else { return }
        gateTimer?.cancel(); gateTimer = nil
        if upstreamOpen { onUpstreamState?(nil); teardown() }
        else { onUpstreamState?(false); respondAndClose(502, "Bad Gateway") }
    }

    private func upgradeClient() {
        let resp = wsHandshakeResponse(accept: wsAcceptKey(for: pendingKey ?? ""))
        client.send(content: resp.data(using: .utf8), completion: .contentProcessed { [weak self] _ in
            guard let self, !self.closed else { return }
            self.upgraded = true
            self.processInbound()
            self.receiveClientLoop()
            self.receiveUpstreamLoop()
        })
    }

    private func respondAndClose(_ status: Int, _ reason: String) {
        let resp = wsBadResponse(status, reason)
        client.send(content: resp.data(using: .utf8), completion: .contentProcessed { [weak self] _ in
            self?.teardown()
        })
    }

    // MARK: client -> upstream

    private func receiveClientLoop() {
        client.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if error != nil { self.teardown(); return }
            if let data, !data.isEmpty {
                self.inbound.append(data)
                self.processInbound()
            }
            if isComplete && (data?.isEmpty ?? true) { self.teardown(); return }
            self.receiveClientLoop()
        }
    }

    private func processInbound() {
        while !closed {
            do {
                guard let frame = try wsParseFrame(buffer: &inbound) else { return }
                if let msg = assembler.feed(frame) {
                    forwardToUpstream(msg)
                }
            } catch {
                teardown(); return
            }
        }
    }

    private func forwardToUpstream(_ msg: WSMessage) {
        switch msg {
        case .text(let s):   sendUpstream(.string(s))
        case .binary(let d): sendUpstream(.data(d))
        case .ping(let d):   sendClient(opcode: .pong, payload: d) // server must answer pings
        case .pong:          break
        case .close:
            sendClient(opcode: .close, payload: Data())
            teardown()
        }
    }

    private func sendUpstream(_ msg: URLSessionWebSocketTask.Message) {
        upstream?.send(msg) { [weak self] err in if err != nil { self?.teardown() } }
    }

    // MARK: upstream -> client

    private func receiveUpstreamLoop() {
        upstream?.receive { [weak self] result in
            guard let self, !self.closed else { return }
            switch result {
            case .failure:
                self.teardown(); return
            case .success(let message):
                switch message {
                case .string(let s): self.sendClient(opcode: .text, payload: Data(s.utf8))
                case .data(let d):   self.sendClient(opcode: .binary, payload: d)
                @unknown default: break
                }
            }
            self.receiveUpstreamLoop()
        }
    }

    private func sendClient(opcode: WSOpcode, payload: Data) {
        client.send(content: wsEncodeFrame(opcode: opcode, payload: payload), // unmasked server frame
                    completion: .contentProcessed { [weak self] err in
            if err != nil { self?.teardown() }
        })
    }

    // MARK: teardown

    fileprivate func teardown() {
        guard !closed else { return }
        closed = true
        gateTimer?.cancel(); gateTimer = nil
        client.cancel()
        upstream?.cancel()
        session?.invalidateAndCancel()
        onTeardown?(self)
    }
}

/// Forwards URLSessionWebSocket lifecycle events back to the owning session.
private final class UpstreamDelegate: NSObject, URLSessionWebSocketDelegate, URLSessionTaskDelegate {
    weak var owner: ProxySession?

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        owner?.upstreamDidOpen()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        owner?.upstreamDidFail()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil { owner?.upstreamDidFail() }
    }
}
