import express from "express";
import http from "http";
import fs from "fs";
import path from "path";
import { Duplex } from "stream";
import { WebSocketServer, WebSocket } from "ws";
import { Agent, ChatTurn } from "./agent";
import { AppConfig, isConfigured, loadConfig, saveConfig, SNAPSHOT_DIR } from "./config";
import { EufyBridge, LiveMetadata } from "./eufy";
import { EventStore } from "./store";

const PORT = Number(process.env.EUFY_BRIDGE_PORT) || 8791;

export class Server {
  private app = express();
  private httpServer = http.createServer(this.app);
  private wss = new WebSocketServer({ noServer: true });
  private streamWss = new WebSocketServer({ noServer: true });
  private chatHistory: ChatTurn[] = [];
  /** Live viewers per device serial. */
  private viewers = new Map<string, Set<WebSocket>>();
  private lastLiveStart = new Map<string, number>();

  constructor(
    private bridge: EufyBridge,
    private store: EventStore,
    private agent: Agent,
  ) {
    this.app.use(express.json({ limit: "2mb" }));
    this.routes();
    this.upgradeRouting();
    this.bridge.on("state", () => this.broadcast({ type: "status", status: this.statusPayload() }));
    this.bridge.on("devices changed", () => this.broadcast({ type: "devices_changed" }));
    this.wireLivestream();
  }

  listen(): void {
    this.httpServer.listen(PORT, "127.0.0.1", () => {
      console.log(`[bridge] API sur http://127.0.0.1:${PORT}`);
    });
  }

  broadcast(message: unknown): void {
    const payload = JSON.stringify(message);
    for (const client of this.wss.clients) {
      if (client.readyState === WebSocket.OPEN) client.send(payload);
    }
  }

  // MARK: WebSocket upgrade routing (/ws = events, /stream/<sn> = live video)

  private upgradeRouting(): void {
    this.httpServer.on("upgrade", (req, socket: Duplex, head) => {
      const url = req.url ?? "";
      if (url === "/ws") {
        this.wss.handleUpgrade(req, socket, head, (ws) => {
          this.wss.emit("connection", ws, req);
        });
      } else if (url.startsWith("/stream/")) {
        const serial = decodeURIComponent(url.slice("/stream/".length).split("?")[0]);
        this.streamWss.handleUpgrade(req, socket, head, (ws) => {
          this.handleStreamViewer(ws, serial);
        });
      } else {
        socket.destroy();
      }
    });
  }

  private handleStreamViewer(ws: WebSocket, serial: string): void {
    let set = this.viewers.get(serial);
    if (!set) {
      set = new Set();
      this.viewers.set(serial, set);
    }
    set.add(ws);

    // If the stream is already up, send metadata right away.
    const metadata = this.bridge.liveMetadata(serial);
    if (metadata) {
      ws.send(JSON.stringify({ type: "metadata", ...metadata }));
    }

    if (set.size === 1) {
      this.lastLiveStart.set(serial, Date.now());
      this.bridge.startLivestream(serial).catch((err) => {
        this.sendStreamError(serial, err instanceof Error ? err.message : String(err));
      });
    }

    ws.on("close", () => {
      set?.delete(ws);
      if (set && set.size === 0) {
        this.viewers.delete(serial);
        this.bridge.stopLivestream(serial).catch(() => {});
      }
    });
  }

  private sendStreamError(serial: string, message: string): void {
    for (const ws of this.viewers.get(serial) ?? []) {
      if (ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({ type: "error", message }));
      }
    }
  }

  private wireLivestream(): void {
    this.bridge.on("livestream started", ({ sn, metadata }: { sn: string; metadata: LiveMetadata }) => {
      for (const ws of this.viewers.get(sn) ?? []) {
        if (ws.readyState === WebSocket.OPEN) {
          ws.send(JSON.stringify({ type: "metadata", ...metadata }));
        }
      }
    });

    this.bridge.on("livestream data", ({ sn, chunk }: { sn: string; chunk: Buffer }) => {
      for (const ws of this.viewers.get(sn) ?? []) {
        if (ws.readyState === WebSocket.OPEN && ws.bufferedAmount < 4_000_000) {
          ws.send(chunk);
        }
      }
    });

    // Eufy stations cut streams after a fixed duration — restart while
    // viewers are still connected, unless the stream died right away.
    this.bridge.on("livestream stopped", ({ sn }: { sn: string }) => {
      const set = this.viewers.get(sn);
      if (!set || set.size === 0) return;
      const startedAt = this.lastLiveStart.get(sn) ?? 0;
      if (Date.now() - startedAt < 3000) {
        this.sendStreamError(sn, "Le flux s'interrompt immédiatement (caméra injoignable ?)");
        return;
      }
      setTimeout(() => {
        if ((this.viewers.get(sn)?.size ?? 0) > 0) {
          this.lastLiveStart.set(sn, Date.now());
          this.bridge.startLivestream(sn).catch((err) => {
            this.sendStreamError(sn, err instanceof Error ? err.message : String(err));
          });
        }
      }, 800);
    });
  }

  // MARK: HTTP routes

  private statusPayload() {
    const cfg = loadConfig();
    return {
      state: this.bridge.state,
      configured: isConfigured(cfg),
      agentEnabled: this.agent.enabled,
      lastError: this.bridge.lastError ?? null,
      captcha: this.bridge.captcha ?? null,
    };
  }

  private routes(): void {
    const wrap =
      (fn: (req: express.Request, res: express.Response) => Promise<void> | void) =>
      async (req: express.Request, res: express.Response) => {
        try {
          await fn(req, res);
        } catch (err) {
          const message = err instanceof Error ? err.message : String(err);
          res.status(500).json({ error: message });
        }
      };

    this.app.get("/api/status", wrap((_req, res) => {
      res.json(this.statusPayload());
    }));

    this.app.post("/api/config", wrap(async (req, res) => {
      const body = req.body as AppConfig;
      const cfg: AppConfig = {
        username: body.username?.trim(),
        password: body.password,
        country: body.country?.trim() || "FR",
        anthropicApiKey: body.anthropicApiKey?.trim(),
      };
      saveConfig(cfg);
      this.agent.configure(cfg.anthropicApiKey);
      res.json({ ok: true });
      await this.bridge.start(cfg);
      this.broadcast({ type: "status", status: this.statusPayload() });
    }));

    this.app.post("/api/captcha", wrap(async (req, res) => {
      const { captchaId, code } = req.body as { captchaId: string; code: string };
      await this.bridge.submitCaptcha(captchaId, code);
      res.json({ ok: true });
    }));

    this.app.post("/api/tfa", wrap(async (req, res) => {
      const { code } = req.body as { code: string };
      await this.bridge.submitTfa(code);
      res.json({ ok: true });
    }));

    this.app.get("/api/devices", wrap(async (_req, res) => {
      res.json(await this.bridge.listDevices());
    }));

    this.app.get("/api/devices/:sn/snapshot", wrap(async (req, res) => {
      const snapshot = await this.bridge.getSnapshot(req.params.sn);
      if (!snapshot) {
        res.status(404).json({ error: "Pas d'image disponible pour cette caméra" });
        return;
      }
      res.setHeader("Content-Type", snapshot.mime);
      res.send(snapshot.data);
    }));

    this.app.post("/api/devices/:sn/ptz", wrap(async (req, res) => {
      const { direction } = req.body as { direction?: string };
      if (!direction) {
        res.status(400).json({ error: "Direction manquante" });
        return;
      }
      await this.bridge.panTilt(req.params.sn, direction);
      res.json({ ok: true });
    }));

    this.app.get("/api/stations", wrap(async (_req, res) => {
      res.json(await this.bridge.listStations());
    }));

    this.app.post("/api/stations/:sn/guard", wrap(async (req, res) => {
      const mode = Number((req.body as { mode?: string | number }).mode);
      if (!Number.isFinite(mode)) {
        res.status(400).json({ error: "Mode invalide" });
        return;
      }
      await this.bridge.setGuardMode(req.params.sn, mode);
      res.json({ ok: true });
    }));

    this.app.get("/api/events", wrap((req, res) => {
      const limit = Math.min(Number(req.query.limit) || 100, 500);
      res.json(this.store.list(limit));
    }));

    this.app.get("/api/events/:id/snapshot", wrap((req, res) => {
      const record = this.store.list(1000).find((e) => e.id === req.params.id);
      if (!record?.snapshotFile) {
        res.status(404).json({ error: "Pas d'image pour cet événement" });
        return;
      }
      const file = path.join(SNAPSHOT_DIR, path.basename(record.snapshotFile));
      if (!fs.existsSync(file)) {
        res.status(404).json({ error: "Image introuvable" });
        return;
      }
      res.setHeader("Content-Type", "image/jpeg");
      fs.createReadStream(file).pipe(res);
    }));

    this.app.post("/api/chat", wrap(async (req, res) => {
      const { message } = req.body as { message: string };
      if (!message?.trim()) {
        res.status(400).json({ error: "Message vide" });
        return;
      }
      const answer = await this.agent.chat(
        message,
        this.store.contextSummary(),
        this.chatHistory.slice(-12),
      );
      this.chatHistory.push({ role: "user", content: message });
      this.chatHistory.push({ role: "assistant", content: answer });
      res.json({ answer });
    }));

    this.app.post("/api/chat/reset", wrap((_req, res) => {
      this.chatHistory = [];
      res.json({ ok: true });
    }));

    this.app.post("/api/digest", wrap(async (req, res) => {
      const hours = Math.min(Number((req.body as { hours?: number | string })?.hours) || 24, 168);
      const question =
        `Fais un rapport de surveillance couvrant les ${hours} dernières heures. Structure : ` +
        `1) vue d'ensemble en une phrase, 2) points notables par caméra (horaires précis), ` +
        `3) alertes éventuelles, 4) statistiques (nb d'événements, personnes, véhicules, colis). ` +
        `Ignore les événements plus anciens que la période demandée.`;
      const answer = await this.agent.chat(question, this.store.contextSummary(300), []);
      res.json({ answer });
    }));
  }
}
