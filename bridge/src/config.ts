import fs from "fs";
import path from "path";

export interface AppConfig {
  username?: string;
  password?: string;
  country?: string;
  anthropicApiKey?: string;
}

export const DATA_DIR = path.join(__dirname, "..", "data");
export const SNAPSHOT_DIR = path.join(DATA_DIR, "snapshots");
export const PERSISTENT_DIR = path.join(DATA_DIR, "eufy");
const CONFIG_PATH = path.join(DATA_DIR, "config.json");

export function ensureDirs(): void {
  for (const dir of [DATA_DIR, SNAPSHOT_DIR, PERSISTENT_DIR]) {
    fs.mkdirSync(dir, { recursive: true });
  }
}

export function loadConfig(): AppConfig {
  try {
    return JSON.parse(fs.readFileSync(CONFIG_PATH, "utf-8"));
  } catch {
    return {};
  }
}

export function saveConfig(cfg: AppConfig): void {
  ensureDirs();
  fs.writeFileSync(CONFIG_PATH, JSON.stringify(cfg, null, 2), { mode: 0o600 });
}

export function isConfigured(cfg: AppConfig): boolean {
  return Boolean(cfg.username && cfg.password);
}
