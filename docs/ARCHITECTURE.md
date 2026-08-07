# EufyGuard — Architecture

EufyGuard est un système à deux processus qui tourne intégralement sur le Mac
de l'utilisateur :

1. **EufyGuard.app** — une application native SwiftUI (macOS 14+). Toute
   l'UI/UX : tableau de bord, vue en direct, timeline d'événements, chat IA,
   réglages, notifications.
2. **Le bridge** (`bridge/`) — un moteur local Node/TypeScript bâti sur
   [`eufy-security-client`](https://github.com/bropat/eufy-security-client).
   Il possède la connexion au cloud Eufy et aux stations (P2P), détecte les
   événements, capture les snapshots, exécute l'analyse Claude et expose une
   API HTTP + WebSocket sur `127.0.0.1:8791`.

Justification : le protocole P2P Eufy n'a d'implémentation open source mature
qu'en Node.js. Plutôt que de le réimplémenter en Swift, l'app native embarque
un moteur Node local et garde tout ce qui est visible par l'utilisateur natif.

![App EufyGuard — tableau de bord (maquette illustrative)](assets/screenshots/dashboard.svg)

```
┌───────────────────────────────┐          ┌───────────────────────────────┐
│ EufyGuard.app (SwiftUI)       │          │ Bridge (Node/TypeScript)      │
│                               │          │                               │
│ BridgeProcess ──── lance ─────┼─────────►│ index.ts (point d'entrée)     │
│ BridgeClient  ◄── HTTP/JSON ──┼──────────┤ server.ts (Express + ws)      │
│               ◄── WS /ws ─────┤          │ eufy.ts   (EufySecurity)      │
│ LiveStream    ◄── WS /stream ─┤          │ agent.ts  (Claude)            │
│ Décodage VideoToolbox         │          │ store.ts  (events.json)       │
└───────────────────────────────┘          └───────────────┬───────────────┘
                                                           │ HTTPS (compte)
                                                           │ P2P (flux)
                                                    Stations & caméras Eufy
```

Le bridge écoute exclusivement sur `127.0.0.1` et n'est jamais joignable
depuis le réseau. L'Info.plist de l'app active `NSAllowsLocalNetworking` pour
ce trafic loopback.

## Supervision du bridge

`BridgeProcess.swift` lance et supervise le moteur :

- Au démarrage de l'app, il sonde `GET /api/status` (timeout 2 s). Si un
  bridge tourne déjà, il le réutilise ; sinon il lance
  `node <bridge>/dist/index.js`.
- Le binaire Node est cherché dans `/opt/homebrew/bin/node`,
  `/usr/local/bin/node`, puis `/usr/bin/node`.
- Le répertoire du bridge est par défaut le checkout de développement et peut
  être surchargé via le user default `bridgePath`
  (`defaults write fr.lauriat.EufyGuard bridgePath …`).
- Si le processus se termine, il est relancé après 5 secondes.
- Le bridge n'est délibérément **pas** tué à la fermeture de l'app : la
  surveillance, la capture d'événements et l'analyse IA continuent en arrière-
  plan. En secours quand l'app est fermée, le bridge poste lui-même une
  notification macOS via `osascript` pour les événements de niveau `alerte`.

## Machine à états de connexion

`eufy.ts` expose une petite machine à états, reflétée dans la barre de statut
de l'app et la feuille de Réglages :

`unconfigured → connecting → (captcha | tfa)* → connected | error`

Les demandes de captcha portent une image base64 affichée dans les Réglages ;
les demandes 2FA invitent à saisir le code reçu par email/SMS. Les deux sont
renvoyées via l'API et reprennent la connexion (`connect()` avec les options
`captcha`/`verifyCode`).

## Flux d'événements (détection → notification)

1. `eufy-security-client` reçoit une notification push d'Eufy et émet un
   événement d'appareil. Le bridge écoute 11 événements de détection
   (mouvement, personne, inconnu, animal, véhicule, chien, son, pleurs,
   sonnette, colis livré, colis pris) et les normalise en une chaîne `kind`
   (front montant uniquement).
2. `index.ts` crée un `EventRecord`, le persiste dans le store
   (`bridge/data/events.json`, plafonné à 1000 événements, écritures
   temporisées) et diffuse `{type:"event"}` sur `/ws` — la timeline se met à
   jour instantanément.
3. Après un délai de 3 secondes (la propriété image de la caméra est
   rafraîchie par les push Eufy, le snapshot a donc besoin d'un instant pour
   correspondre à l'événement), le bridge lit `DevicePicture` et enregistre le
   JPEG dans `bridge/data/snapshots/<eventId>.jpg`.
4. Si l'agent IA est configuré, le snapshot est envoyé à Claude
   (`claude-opus-5`, vision) avec un **schéma JSON de sortie structurée**
   (effort low) : `resume`, `personnes`, `vehicules`, `animaux`, `colis`,
   `niveau_alerte` (`info` | `attention` | `alerte`).
5. L'enregistrement mis à jour est diffusé en `{type:"event_updated"}`. L'app
   poste une notification native : `🚨 ALERTE` pour `alerte`, `⚠️` pour
   `attention`, ou une notification d'événement simple quand aucune analyse
   n'est disponible. Les événements `info` restent silencieux.

## Flux livestream (P2P → WebSocket → VideoToolbox)

La vidéo en direct ne passe jamais par ffmpeg ni aucun transcodeur ; le flux
élémentaire brut est relayé tel quel et décodé en matériel sur le Mac.

1. L'app ouvre `ws://127.0.0.1:8791/stream/<serial>`. Le premier spectateur
   sur un serial déclenche `startStationLivestream()` ; la déconnexion du
   dernier spectateur l'arrête.
2. `eufy-security-client` établit la session P2P et émet un flux vidéo. Le
   bridge capture ses métadonnées (codec H.264 ou H.265, dimensions, fps) et
   les envoie aux spectateurs en trame texte JSON
   (`{type:"metadata", codec, width, height, fps}`), puis relaie chaque chunk
   vidéo en trame WebSocket **binaire** (flux élémentaire Annex-B brut). Les
   spectateurs lents (> 4 Mo en tampon) sautent des chunks au lieu d'accumuler
   de la latence. L'audio est drainé et pas encore relayé (Phase 3).
3. Les stations Eufy coupent les flux après une durée fixe ; le bridge
   relance le flux (800 ms plus tard) tant que des spectateurs restent
   connectés. Un flux qui meurt moins de 3 secondes après son démarrage est
   traité comme une erreur « caméra injoignable ».
4. Dans l'app, `NALUStreamDecoder` parse le flux Annex-B : il extrait SPS/PPS
   (et VPS pour le H.265) pour construire une `CMVideoFormatDescription`,
   convertit chaque NAL de frame en framing AVCC/HVCC (préfixe de longueur
   4 octets) et produit des `CMSampleBuffer` marqués `DisplayImmediately`.
5. `AVSampleBufferDisplayLayer` (VideoToolbox) décode et affiche les samples
   en matériel. Sur les caméras motorisées, un pad PTZ est superposé (boutons,
   flèches clavier, `R` pour un tour à 360°) et appelle l'endpoint PTZ du
   bridge.

## Agent IA

- Modèle : **`claude-opus-5`** (SDK Anthropic), configuré avec la clé API de
  l'utilisateur. Sans clé, `agentEnabled` est false et tout le reste continue
  de fonctionner.
- **Analyse vision** : une image + contexte (nom de la caméra, type
  d'événement), sortie au schéma JSON avec `effort: "low"` — économique,
  rapide, forme déterministe.
- **Chat** : le prompt système embarque un journal texte compact des 60
  derniers événements (avec leurs analyses) et la date/heure courantes ; les
  12 derniers tours de chat sont rejoués. Réponses en français.
- **Digest** : `POST /api/digest` réutilise le chemin du chat avec un prompt
  de rapport fixe sur les 300 derniers événements, pour une période allant
  jusqu'à 168 heures (24 par défaut).

## Modes de garde et PTZ

- Le mode de garde est lu/écrit par station via la propriété
  `StationGuardMode`. L'app expose quatre modes : Domicile (1), Absent (0),
  Programmé (2), Désarmé (63).
- Le PTZ mappe `left/right/up/down/rotate360` sur les commandes
  `PanTiltDirection`, protégé par une vérification de la capacité
  `DevicePanAndTilt`.

## Composants Swift (app/Sources)

| Fichier | Rôle |
|---|---|
| `EufyGuardApp.swift` | Point d'entrée ; démarre `BridgeProcess` et `BridgeClient`. |
| `ContentView.swift` | Sidebar (sections + liste des caméras avec batterie), barre de statut, grille du tableau de bord (`CameraCard`, `SnapshotImage`), timeline des événements, menu des modes de garde. |
| `ChatView.swift` | Panneau de chat IA (messages, bouton digest). |
| `SettingsView.swift` | Identifiants Eufy, clé Anthropic, image + code captcha, code 2FA, affichage des erreurs. |
| `BridgeClient.swift` | Client HTTP + WebSocket `/ws` ; publie statut, appareils, stations, événements, chat ; rafraîchissement par polling toutes les 15 s ; déclenche les notifications. |
| `BridgeProcess.swift` | Lance et supervise le bridge Node (voir plus haut). |
| `NotificationManager.swift` | Autorisation UserNotifications + envoi. |
| `Models.swift` | Miroirs Codable des payloads du bridge (`BridgeStatus`, `DeviceInfo`, `StationInfo`, `EventRecord`, `Analysis`). |
| `Live/LiveStreamController.swift` | Client WebSocket `/stream/<sn>` ; état de connexion ; alimente le décodeur. |
| `Live/VideoDecoder.swift` | `NALUStreamDecoder` — parsing Annex-B, format description, construction des `CMSampleBuffer`. |
| `Live/LivePlayerView.swift` | Vue hôte de l'`AVSampleBufferDisplayLayer`, feuille de direct plein cadre, pad PTZ. |

## Modules TypeScript (bridge/src)

| Module | Rôle |
|---|---|
| `index.ts` | Point d'entrée ; câble store, agent, bridge, serveur ; pipeline de détection (snapshot → analyse → diffusion) ; notification de secours via `osascript`. |
| `server.ts` | API HTTP Express + deux serveurs WebSocket (`/ws` événements, `/stream/<sn>` vidéo) ; comptage des spectateurs et relance automatique du flux. |
| `eufy.ts` | Wrapper `EufySecurity` : connexion (captcha/2FA), machine à états, liste des appareils/stations, mode de garde, PTZ, snapshots, événements de livestream. |
| `agent.ts` | Client Anthropic : analyse vision structurée et chat contextualisé (`claude-opus-5`). |
| `store.ts` | Persistance des événements (`events.json`, max 1000, sauvegardes temporisées) et `contextSummary` texte fourni à l'agent de chat. |
| `config.ts` | Lecture/écriture de `config.json` (mode `0600`), répertoires de données (`data/`, `data/snapshots/`, `data/eufy/`). |

## Données sur disque (`bridge/data/`, ignoré par git)

| Chemin | Contenu |
|---|---|
| `config.json` | Identifiants Eufy, pays, clé API Anthropic. |
| `events.json` | Les 1000 derniers événements avec leurs analyses. |
| `snapshots/*.jpg` | Un JPEG par événement. |
| `eufy/` | État persistant d'`eufy-security-client` (jetons, cache des appareils). |
