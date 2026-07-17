// Bun WebSocket echo server for integration testing.
// Usage: bun echo-server.ts <port>
const port = Number(process.argv[2]);
Bun.serve({
  port,
  hostname: "127.0.0.1",
  fetch(req, server) {
    if (server.upgrade(req)) return;
    return new Response("Upgrade required", { status: 426 });
  },
  websocket: {
    message(ws, msg) { ws.send(msg); },
  },
});
