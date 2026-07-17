import XCTest
import Network
import Darwin
@testable import ProxyCore

/// End-to-end: a real WS client talks through `WebSocketServer` to a real bun WS **echo**
/// upstream. Validates the full bridge: handshake, upstream-open gate, and bidirectional
/// message piping. The 502 test validates the gate when the upstream is unreachable.

private func freePort() -> UInt16? {
    // ponytail: deterministic ephemeral port via BSD sockets; small TOCTOU is fine for a test.
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &addr) { p -> Int32 in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard bound == 0 else { return nil }
    var out = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let got = withUnsafeMutablePointer(to: &out) { p -> Int32 in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
    }
    guard got == 0 else { return nil }
    return UInt16(bigEndian: out.sin_port)
}

private func waitUntilListening(_ port: UInt16, timeout: TimeInterval = 5) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var target = sockaddr_in()
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = in_port_t(port).bigEndian
        target.sin_addr.s_addr = inet_addr("127.0.0.1")
        let r = withUnsafePointer(to: &target) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        close(fd)
        if r == 0 { return true }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return false
}

private func bunExecutable() -> String? {
    let candidates = ["/opt/homebrew/bin/bun", "/usr/local/bin/bun",
                      FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".bun/bin/bun").path]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}

private func echoServerPath() -> String {
    URL(fileURLWithPath: #file)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("echo-server.ts")
        .path
}

final class IntegrationTests: XCTestCase {

    func testBridgesTextRoundTrip() throws {
        guard let bun = bunExecutable() else {
            throw XCTSkip("bun not installed; skipping live echo test")
        }
        let upstreamPort = try XCTUnwrap(freePort())
        let proxyPort = try XCTUnwrap(freePort())

        // Real bun WS echo as the upstream.
        let echo = Process()
        echo.executableURL = URL(fileURLWithPath: bun)
        echo.arguments = [echoServerPath(), String(upstreamPort)]
        try echo.run()
        defer { echo.terminate() }
        XCTAssertTrue(waitUntilListening(upstreamPort), "echo upstream never came up")

        let proxy = WebSocketServer(localHost: "127.0.0.1", localPort: proxyPort,
                                    remoteHost: "127.0.0.1", remotePort: upstreamPort)
        try proxy.start()
        defer { proxy.stop() }
        XCTAssertTrue(waitUntilListening(proxyPort), "proxy never came up")

        let exp = expectation(description: "client receives echo through proxy")
        let task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(proxyPort)")!)
        task.resume()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            task.send(.string("hello proxy")) { _ in }
        }
        task.receive { result in
            if case .success(.string(let s)) = result, s == "hello proxy" { exp.fulfill() }
        }
        wait(for: [exp], timeout: 10)
        task.cancel(with: .goingAway, reason: nil)
    }

    func testClientGets502WhenUpstreamDown() throws {
        let proxyPort = try XCTUnwrap(freePort())
        let deadPort = try XCTUnwrap(freePort()) // nothing listening here

        let proxy = WebSocketServer(localHost: "127.0.0.1", localPort: proxyPort,
                                    remoteHost: "127.0.0.1", remotePort: deadPort)
        try proxy.start()
        defer { proxy.stop() }
        XCTAssertTrue(waitUntilListening(proxyPort), "proxy never came up")

        let exp = expectation(description: "client connection fails with 502")
        let task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(proxyPort)")!)
        task.resume()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            task.send(.string("nope")) { _ in }
        }
        task.receive { result in
            if case .failure = result { exp.fulfill() } // 502 aborts the upgrade
        }
        wait(for: [exp], timeout: 10)
        task.cancel(with: .goingAway, reason: nil)
    }
}
