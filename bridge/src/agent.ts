import Anthropic from "@anthropic-ai/sdk";
import { Analysis } from "./store";

const MODEL = "claude-opus-5";

const ANALYSIS_SCHEMA = {
  type: "object",
  properties: {
    resume: {
      type: "string",
      description: "Description courte en français de ce qui est visible (1-2 phrases)",
    },
    personnes: { type: "integer", description: "Nombre de personnes visibles" },
    vehicules: { type: "integer", description: "Nombre de véhicules visibles" },
    animaux: { type: "boolean", description: "Un animal est-il visible" },
    colis: { type: "boolean", description: "Un colis ou une livraison est-il visible" },
    niveau_alerte: {
      type: "string",
      enum: ["info", "attention", "alerte"],
      description:
        "info: rien de notable. attention: présence humaine/véhicule inhabituel à vérifier. alerte: comportement suspect (rôde, tente d'ouvrir, cagoule, intrusion...)",
    },
  },
  required: ["resume", "personnes", "vehicules", "animaux", "colis", "niveau_alerte"],
  additionalProperties: false,
} as const;

export interface ChatTurn {
  role: "user" | "assistant";
  content: string;
}

export class Agent {
  private client?: Anthropic;

  configure(apiKey?: string): void {
    this.client = apiKey ? new Anthropic({ apiKey }) : undefined;
  }

  get enabled(): boolean {
    return Boolean(this.client);
  }

  async analyzeSnapshot(
    jpegBase64: string,
    ctx: { deviceName: string; kind: string },
  ): Promise<Analysis> {
    if (!this.client) throw new Error("Agent IA non configuré (clé API manquante)");
    const response = await this.client.messages.create({
      model: MODEL,
      max_tokens: 2048,
      output_config: {
        effort: "low",
        format: { type: "json_schema", schema: ANALYSIS_SCHEMA as unknown as Record<string, unknown> },
      },
      messages: [
        {
          role: "user",
          content: [
            {
              type: "image",
              source: { type: "base64", media_type: "image/jpeg", data: jpegBase64 },
            },
            {
              type: "text",
              text:
                `Image capturée par la caméra de surveillance "${ctx.deviceName}" suite à un événement de type "${ctx.kind}". ` +
                `Analyse la scène pour un système de surveillance domestique et remplis le schéma demandé. Réponds en français.`,
            },
          ],
        },
      ],
    } as Anthropic.MessageCreateParamsNonStreaming);
    if (response.stop_reason === "refusal") {
      throw new Error("Analyse refusée par le modèle");
    }
    const text = response.content.find((b) => b.type === "text");
    if (!text || text.type !== "text") throw new Error("Réponse sans texte");
    return JSON.parse(text.text) as Analysis;
  }

  async chat(question: string, eventsContext: string, history: ChatTurn[]): Promise<string> {
    if (!this.client) throw new Error("Agent IA non configuré (clé API manquante)");
    const response = await this.client.messages.create({
      model: MODEL,
      max_tokens: 4096,
      system:
        "Tu es EufyGuard, l'agent de surveillance domestique de Vincent. Tu as accès au journal des " +
        "événements détectés par ses caméras Eufy (ci-dessous). Réponds en français, de façon concise et " +
        "factuelle. Si on te demande un résumé, structure-le par caméra ou par période. Si une information " +
        "n'est pas dans le journal, dis-le simplement.\n\n" +
        `Journal des événements récents (du plus ancien au plus récent) :\n${eventsContext}\n\n` +
        `Date et heure actuelles : ${new Date().toLocaleString("fr-FR")}`,
      messages: [...history, { role: "user", content: question }],
    });
    if (response.stop_reason === "refusal") {
      return "Je ne peux pas répondre à cette demande.";
    }
    return response.content
      .filter((b): b is Anthropic.TextBlock => b.type === "text")
      .map((b) => b.text)
      .join("\n");
  }
}
