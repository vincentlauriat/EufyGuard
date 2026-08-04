import { EventEmitter } from "events";
import {
  CommandName,
  Device,
  EufySecurity,
  EufySecurityConfig,
  P2PConnectionType,
  PanTiltDirection,
  PropertyName,
} from "eufy-security-client";
import { AppConfig, PERSISTENT_DIR } from "./config";

export type BridgeState =
  | "unconfigured"
  | "connecting"
  | "captcha"
  | "tfa"
  | "connected"
  | "error";

export interface DeviceInfo {
  serial: string;
  name: string;
  model: string;
  stationSerial: string;
  hasBattery: boolean;
  battery?: number;
  enabled: boolean;
  canPanTilt: boolean;
}

const PTZ_DIRECTIONS: Record<string, PanTiltDirection> = {
  left: PanTiltDirection.LEFT,
  right: PanTiltDirection.RIGHT,
  up: PanTiltDirection.UP,
  down: PanTiltDirection.DOWN,
  rotate360: PanTiltDirection.ROTATE360,
};

export interface Detection {
  deviceSn: string;
  deviceName: string;
  kind: string;
}

export interface StationInfo {
  serial: string;
  name: string;
  model: string;
  guardMode: number;
}

export interface LiveMetadata {
  codec: "h264" | "h265";
  width?: number;
  height?: number;
  fps?: number;
}

/** Client-level detection events → normalized kind. Registered dynamically
 *  (cast to any) so a missing event name in a lib version doesn't break. */
const DETECTION_EVENTS: Array<[string, string]> = [
  ["device motion detected", "mouvement"],
  ["device person detected", "personne"],
  ["device stranger person detected", "inconnu"],
  ["device pet detected", "animal"],
  ["device vehicle detected", "véhicule"],
  ["device dog detected", "chien"],
  ["device sounds detected", "son"],
  ["device crying detected", "pleurs"],
  ["device rings", "sonnette"],
  ["device package delivered", "colis livré"],
  ["device package taken", "colis pris"],
];

export class EufyBridge extends EventEmitter {
  state: BridgeState = "unconfigured";
  lastError?: string;
  captcha?: { id: string; image: string };
  private client?: EufySecurity;
  private liveMeta = new Map<string, LiveMetadata>();
  private activeStreams = new Set<string>();

  async start(cfg: AppConfig): Promise<void> {
    if (!cfg.username || !cfg.password) {
      this.setState("unconfigured");
      return;
    }
    await this.stop();
    this.setState("connecting");
    try {
      const config: EufySecurityConfig = {
        username: cfg.username,
        password: cfg.password,
        country: cfg.country || "FR",
        persistentDir: PERSISTENT_DIR,
        p2pConnectionSetup: P2PConnectionType.QUICKEST,
        pollingIntervalMinutes: 10,
        eventDurationSeconds: 10,
        acceptInvitations: true,
      } as EufySecurityConfig;
      this.client = await EufySecurity.initialize(config);
      this.registerHandlers(this.client);
      await this.client.connect();
    } catch (err) {
      this.lastError = err instanceof Error ? err.message : String(err);
      this.setState("error");
    }
  }

  async stop(): Promise<void> {
    if (this.client) {
      try {
        this.client.close();
      } catch {
        /* ignore */
      }
      this.client = undefined;
    }
  }

  async submitCaptcha(captchaId: string, captchaCode: string): Promise<void> {
    if (!this.client) throw new Error("Client non initialisé");
    this.captcha = undefined;
    this.setState("connecting");
    // Both LoginOptions shapes exist across lib versions — pass both.
    await (this.client as any).connect({
      captcha: { captchaId, captchaCode },
      captchaId,
      captchaCode,
    });
  }

  async submitTfa(verifyCode: string): Promise<void> {
    if (!this.client) throw new Error("Client non initialisé");
    this.setState("connecting");
    await (this.client as any).connect({ verifyCode });
  }

  async listDevices(): Promise<DeviceInfo[]> {
    if (!this.client) return [];
    const devices = await this.client.getDevices();
    return devices.filter((d) => d.isCamera()).map((d) => this.toInfo(d));
  }

  async listStations(): Promise<StationInfo[]> {
    if (!this.client) return [];
    const stations = await this.client.getStations();
    return stations.map((s) => {
      const guardMode = s.getPropertyValue(PropertyName.StationGuardMode);
      return {
        serial: s.getSerial(),
        name: s.getName(),
        model: s.getModel(),
        guardMode: typeof guardMode === "number" ? guardMode : -1,
      };
    });
  }

  async setGuardMode(stationSerial: string, mode: number): Promise<void> {
    if (!this.client) throw new Error("Non connecté");
    await this.client.setStationProperty(stationSerial, PropertyName.StationGuardMode, mode);
    this.emit("devices changed");
  }

  async panTilt(serial: string, direction: string): Promise<void> {
    if (!this.client) throw new Error("Non connecté");
    const ptzDirection = PTZ_DIRECTIONS[direction];
    if (ptzDirection === undefined) throw new Error(`Direction inconnue: ${direction}`);
    const device = await this.client.getDevice(serial);
    if (!device.hasCommand(CommandName.DevicePanAndTilt)) {
      throw new Error("Cette caméra n'est pas motorisée");
    }
    const station = await this.client.getStation(device.getStationSerial());
    station.panAndTilt(device, ptzDirection);
  }

  // MARK: Livestream

  liveMetadata(serial: string): LiveMetadata | undefined {
    return this.liveMeta.get(serial);
  }

  async startLivestream(serial: string): Promise<void> {
    if (!this.client) throw new Error("Non connecté");
    if (this.activeStreams.has(serial)) return;
    try {
      await this.client.startStationLivestream(serial);
    } catch (err) {
      // Already-running streams are fine, everything else bubbles up.
      const message = err instanceof Error ? err.message : String(err);
      if (!/already/i.test(message)) throw err;
    }
  }

  async stopLivestream(serial: string): Promise<void> {
    if (!this.client) return;
    try {
      await this.client.stopStationLivestream(serial);
    } catch {
      /* ignore */
    }
  }

  async getSnapshot(serial: string): Promise<{ data: Buffer; mime: string } | undefined> {
    if (!this.client) return undefined;
    const device = await this.client.getDevice(serial);
    const picture = device.getPropertyValue(PropertyName.DevicePicture) as
      | { data?: Buffer; type?: { mime?: string } }
      | undefined;
    if (picture?.data && picture.data.length > 0) {
      return { data: Buffer.from(picture.data), mime: picture.type?.mime ?? "image/jpeg" };
    }
    return undefined;
  }

  private toInfo(d: Device): DeviceInfo {
    const battery = d.getPropertyValue(PropertyName.DeviceBattery);
    const enabled = d.getPropertyValue(PropertyName.DeviceEnabled);
    return {
      serial: d.getSerial(),
      name: d.getName(),
      model: d.getModel(),
      stationSerial: d.getStationSerial(),
      hasBattery: d.hasBattery(),
      battery: typeof battery === "number" ? battery : undefined,
      enabled: enabled !== false,
      canPanTilt: d.hasCommand(CommandName.DevicePanAndTilt),
    };
  }

  private registerHandlers(client: EufySecurity): void {
    client.on("connect", () => {
      this.captcha = undefined;
      this.setState("connected");
    });
    client.on("close", () => {
      if (this.state === "connected") this.setState("connecting");
    });
    client.on("connection error", (error: Error) => {
      this.lastError = error.message;
      this.setState("error");
    });
    client.on("captcha request", (id: string, captcha: string) => {
      this.captcha = { id, image: captcha };
      this.setState("captcha");
    });
    client.on("tfa request", () => {
      this.setState("tfa");
    });
    client.on("device added", (device: Device) => {
      this.emit("devices changed");
      void device;
    });
    client.on("device removed", () => this.emit("devices changed"));

    (client as any).on(
      "station livestream start",
      (_station: unknown, device: Device, metadata: any, videostream: NodeJS.ReadableStream, audiostream: NodeJS.ReadableStream) => {
        const sn = device.getSerial();
        const meta: LiveMetadata = {
          codec: metadata?.videoCodec === 1 ? "h265" : "h264",
          width: metadata?.videoWidth,
          height: metadata?.videoHeight,
          fps: metadata?.videoFPS,
        };
        this.liveMeta.set(sn, meta);
        this.activeStreams.add(sn);
        this.emit("livestream started", { sn, metadata: meta });
        videostream.on("data", (chunk: Buffer) => this.emit("livestream data", { sn, chunk }));
        videostream.on("error", () => {});
        // Audio is not relayed yet — drain it to avoid backpressure.
        audiostream.on("data", () => {});
        audiostream.on("error", () => {});
      },
    );
    (client as any).on("station livestream stop", (_station: unknown, device: Device) => {
      const sn = device.getSerial();
      this.activeStreams.delete(sn);
      this.emit("livestream stopped", { sn });
    });

    for (const [eventName, kind] of DETECTION_EVENTS) {
      (client as any).on(eventName, (device: Device, state: boolean) => {
        if (state === false) return; // only rising edge
        try {
          const detection: Detection = {
            deviceSn: device.getSerial(),
            deviceName: device.getName(),
            kind,
          };
          this.emit("detection", detection);
        } catch {
          /* ignore malformed events */
        }
      });
    }
  }

  private setState(state: BridgeState): void {
    if (this.state !== state) {
      this.state = state;
      this.emit("state", state);
    }
  }
}
