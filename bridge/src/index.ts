import { execFile } from "child_process";
import fs from "fs";
import path from "path";
import { Agent } from "./agent";
import { ensureDirs, loadConfig, SNAPSHOT_DIR } from "./config";
import { Detection, EufyBridge } from "./eufy";
import { Server } from "./server";
import { EventRecord, EventStore } from "./store";

async function main(): Promise<void> {
  ensureDirs();
  const cfg = loadConfig();

  const store = new EventStore();
  store.load();

  const agent = new Agent();
  agent.configure(cfg.anthropicApiKey);

  const bridge = new EufyBridge();
  const server = new Server(bridge, store, agent);
  server.listen();

  bridge.on("detection", (detection: Detection) => {
    void handleDetection(detection, bridge, store, agent, server);
  });

  await bridge.start(cfg);
}

async function handleDetection(
  detection: Detection,
  bridge: EufyBridge,
  store: EventStore,
  agent: Agent,
  server: Server,
): Promise<void> {
  const record: EventRecord = {
    id: `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
    ts: Date.now(),
    deviceSn: detection.deviceSn,
    deviceName: detection.deviceName,
    kind: detection.kind,
  };
  store.add(record);
  server.broadcast({ type: "event", event: record });
  console.log(`[event] ${detection.deviceName}: ${detection.kind}`);

  // The camera picture property is refreshed via push notifications —
  // wait a moment so the snapshot matches this event.
  await sleep(3000);
  try {
    const snapshot = await bridge.getSnapshot(detection.deviceSn);
    if (snapshot) {
      const file = `${record.id}.jpg`;
      fs.writeFileSync(path.join(SNAPSHOT_DIR, file), snapshot.data);
      store.update(record.id, { snapshotFile: file });

      if (agent.enabled) {
        try {
          const analysis = await agent.analyzeSnapshot(snapshot.data.toString("base64"), {
            deviceName: detection.deviceName,
            kind: detection.kind,
          });
          store.update(record.id, { analysis });
          if (analysis.niveau_alerte === "alerte") {
            notifyMac("EufyGuard — ALERTE", `${detection.deviceName} : ${analysis.resume}`);
          }
        } catch (err) {
          store.update(record.id, {
            analysisError: err instanceof Error ? err.message : String(err),
          });
        }
      }
    }
  } catch (err) {
    console.error(`[event] snapshot/analyse en échec: ${err}`);
  }
  const updated = store.list(1000).find((e) => e.id === record.id) ?? record;
  server.broadcast({ type: "event_updated", event: updated });
}

/** Fallback notification when the macOS app is not running. */
function notifyMac(title: string, body: string): void {
  const script = `display notification ${JSON.stringify(body)} with title ${JSON.stringify(title)} sound name "Sosumi"`;
  execFile("osascript", ["-e", script], () => {});
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

main().catch((err) => {
  console.error("[bridge] erreur fatale:", err);
  process.exit(1);
});
