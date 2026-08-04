import fs from "fs";
import path from "path";
import { DATA_DIR } from "./config";

export interface Analysis {
  resume: string;
  personnes: number;
  vehicules: number;
  animaux: boolean;
  colis: boolean;
  niveau_alerte: "info" | "attention" | "alerte";
}

export interface EventRecord {
  id: string;
  ts: number;
  deviceSn: string;
  deviceName: string;
  kind: string;
  snapshotFile?: string;
  analysis?: Analysis;
  analysisError?: string;
}

const EVENTS_PATH = path.join(DATA_DIR, "events.json");
const MAX_EVENTS = 1000;

export class EventStore {
  private events: EventRecord[] = [];
  private saveTimer?: NodeJS.Timeout;

  load(): void {
    try {
      this.events = JSON.parse(fs.readFileSync(EVENTS_PATH, "utf-8"));
    } catch {
      this.events = [];
    }
  }

  add(record: EventRecord): void {
    this.events.push(record);
    if (this.events.length > MAX_EVENTS) {
      this.events = this.events.slice(-MAX_EVENTS);
    }
    this.scheduleSave();
  }

  update(id: string, patch: Partial<EventRecord>): EventRecord | undefined {
    const record = this.events.find((e) => e.id === id);
    if (record) {
      Object.assign(record, patch);
      this.scheduleSave();
    }
    return record;
  }

  list(limit = 100): EventRecord[] {
    return this.events.slice(-limit).reverse();
  }

  /** Compact text summary of recent events, fed to the chat agent. */
  contextSummary(limit = 60): string {
    const recent = this.events.slice(-limit);
    if (recent.length === 0) return "Aucun événement enregistré pour le moment.";
    return recent
      .map((e) => {
        const date = new Date(e.ts).toLocaleString("fr-FR");
        const analysis = e.analysis
          ? ` — analyse: ${e.analysis.resume} (alerte: ${e.analysis.niveau_alerte}, personnes: ${e.analysis.personnes}, véhicules: ${e.analysis.vehicules}${e.analysis.colis ? ", colis détecté" : ""})`
          : "";
        return `[${date}] ${e.deviceName} : ${e.kind}${analysis}`;
      })
      .join("\n");
  }

  private scheduleSave(): void {
    if (this.saveTimer) return;
    this.saveTimer = setTimeout(() => {
      this.saveTimer = undefined;
      fs.writeFile(EVENTS_PATH, JSON.stringify(this.events), () => {});
    }, 1000);
  }
}
