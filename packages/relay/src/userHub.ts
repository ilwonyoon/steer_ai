import type { Env, WSMessage } from "./types.js";

/**
 * Per-user Durable Object. One DO instance per user_id; every
 * authenticated WebSocket from that user lands here. When the Mac
 * pushes a card, the route handler forwards a `card.upsert` message
 * to this DO and we fan it out to every connected socket. iPhone
 * read clients receive it in real time.
 *
 * Why DO instead of plain Workers + KV broadcast: WebSocket fanout
 * needs in-memory connection lists per user, which Workers don't
 * provide on their own. DOs give us a singleton with state.
 */
export class UserHub {
  private state: DurableObjectState;
  private sockets = new Set<WebSocket>();

  constructor(state: DurableObjectState, _env: Env) {
    this.state = state;
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/connect") {
      // Workers WebSocket pair: one returned to the client, the other
      // accepted server-side and hibernated by Cloudflare so we don't
      // pay for idle billing.
      if (request.headers.get("Upgrade") !== "websocket") {
        return new Response("expected websocket", { status: 400 });
      }
      const pair = new WebSocketPair();
      const [client, server] = Object.values(pair);
      this.acceptSocket(server);
      return new Response(null, { status: 101, webSocket: client });
    }

    if (url.pathname === "/broadcast" && request.method === "POST") {
      const message = (await request.json()) as WSMessage;
      this.broadcast(message);
      return new Response(JSON.stringify({ ok: true, recipients: this.sockets.size }), {
        headers: { "Content-Type": "application/json" },
      });
    }

    return new Response("not found", { status: 404 });
  }

  private acceptSocket(socket: WebSocket) {
    socket.accept();
    this.sockets.add(socket);
    socket.addEventListener("message", (evt) => this.onSocketMessage(socket, evt));
    socket.addEventListener("close", () => this.sockets.delete(socket));
    socket.addEventListener("error", () => this.sockets.delete(socket));
    this.send(socket, { type: "ping" });
  }

  private onSocketMessage(socket: WebSocket, evt: MessageEvent) {
    if (typeof evt.data !== "string") return;
    try {
      const parsed = JSON.parse(evt.data) as WSMessage;
      // Right now the only thing clients send back is "pong" — we
      // don't accept arbitrary writes over the socket; all writes
      // go through the REST routes for an audit trail in D1.
      if (parsed.type === "ping") {
        this.send(socket, { type: "pong" });
      }
    } catch {
      // ignore malformed
    }
  }

  private send(socket: WebSocket, message: WSMessage) {
    try {
      socket.send(JSON.stringify(message));
    } catch {
      this.sockets.delete(socket);
    }
  }

  private broadcast(message: WSMessage) {
    for (const socket of this.sockets) {
      this.send(socket, message);
    }
  }
}
