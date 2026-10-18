# Source layout

| Directory | Responsibility |
| --- | --- |
| `Cuse/App` | Lifecycle, hotkeys, shared state, and mode coordination |
| `Cuse/Voice` | Gemini Live WebSocket, microphone, audio playback, session |
| `Cuse/Jev` | Local Laya client, validated target decisions, bounded click loop, results view |
| `Cuse/Laya` | On-device multilingual checkpoint server launched from Application Support |
| `Cuse/Combined` | Combined mode: Gemini Flash per-step planner and the loop where Laya executes its plan |
| `Cuse/Core` | Shared engine, action requests, highlight source resolution, harness contract |
| `Cuse/Actions` | Desktop input facade and CUA driver |
| `Cuse/Workflow` | Action schema, local grounding, execution, pause and validation rules |
| `Cuse/Perception` | AX, browser geometry, CoreML/OCR, screenshots, target cache |
| `Cuse/Harnesses` | Localhost HTTP access to the engine |
| `Cuse/Skills` | Portable markdown app guidance and small runtime hints |
| `Cuse/UI` | Menu bar, Settings, command panel, pointer and detection overlays |
| `Cuse/Utilities` | Permissions, Keychain, preferences, shortcuts, logging and analytics |

Gemini, Laya and Combined use the same action engine. Keep provider networking in their respective directories, execution in the action/workflow layer, and app-specific quirks in markdown skills. Neither UI nor providers should bypass the engine's action permissions or pauses.

The app has no recording, image-generation, hosted-key proxy, Claude planner, or Hermes integration. General documentation stays outside the bundled `Cuse` directory.
