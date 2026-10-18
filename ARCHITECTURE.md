# Cuse architecture

This is a deeper technical map than [README.md](README.md) and [docs/source-layout.md](docs/source-layout.md). It explains how the three modes share one execution engine and where each new component (added for **Combined** mode) fits.

## Modes at a glance

```
                     ┌───────────────────────────────────────────────┐
                     │                CompanionManager                │
                     │  selected mode · hotkeys · permissions · UI   │
                     └───────────────┬───────────┬───────────────────┘
                                     │           │
       Ctrl+K (Laya) / Ctrl+L (Combined)         │ Ctrl+Option (Gemini realtime)
                                     │           │
                 ┌───────────────────┴───┐   ┌───▼──────────────────────┐
                 │  TextCommandPanel      │   │ GeminiLiveSession/Client │
                 │  submitTextCommand()   │   │ WebSocket voice + tools  │
                 └──────────┬─────────────┘   └───────────┬──────────────┘
                            │                              │
              mode == .jev  │  mode == .combined            │
                            │                              │
                  ┌─────────▼──────────┐      ┌────────────▼───────────┐
                  │  JevPointerLoop      │      │ (same engine, driven   │
                  │  Laya picks & clicks │      │  by Gemini tool calls) │
                  └─────────┬────────────┘      └────────────┬───────────┘
                            │                                │
                  ┌─────────▼────────────┐                   │
                  │ CombinedPointerLoop   │                   │
                  │ Gemini plans (Flash), │                   │
                  │ Laya matches the box  │                   │
                  └─────────┬────────────┘                   │
                            │                                │
                            └───────────────┬────────────────┘
                                            │
                                 ┌──────────▼───────────┐
                                 │      CuseEngine       │
                                 │  observe/ground/act   │
                                 └──────────┬───────────┘
                                            │
                          ┌─────────────────┼─────────────────┐
                          │                 │                 │
                 ┌────────▼───────┐ ┌───────▼────────┐ ┌──────▼───────┐
                 │ WorkflowRunner  │ │ Perception      │ │ Harness      │
                 │ pauses, tokens, │ │ AX / browser /  │ │ 127.0.0.1:   │
                 │ post-checks     │ │ CoreML+OCR /    │ │ 19474 for    │
                 │                 │ │ screenshots     │ │ dev clients  │
                 └────────┬───────┘ └────────────────┘ └──────────────┘
                          │
                 ┌────────▼────────────┐
                 │ ActionExecutor /     │
                 │ CuseActionDriver     │
                 │ delivers CUA input   │
                 └─────────────────────┘
```

Every mode ends up at the same `CuseEngine` → `WorkflowRunner` → `ActionExecutor` path. No mode is allowed to move the cursor or synthesize input on its own — that boundary is enforced by construction: providers only ever call `engine.runPointerAction(...)` or the targetless workflow-step path, never AppKit event APIs directly.

## Grounding order

Whenever something needs a screen coordinate, Cuse tries, in order:

1. **Exact local IDs/marks** — an ID or mark returned by a previous local-detection pass, re-validated against the current frame (`LocalTargetContinuity`) so a stale label can't be clicked after the UI shifted.
2. **Accessibility (AX)** tree lookups.
3. **Browser DOM/CDP** geometry, for web content.
4. **Local CoreML/OCR** detection (`NativeElementDetector`), cached per frame in `LocalPerceptionTargetCache`.
5. **Gemini screenshot coordinates** — only for Gemini realtime's point-only/screenshot planning path, and only as a last resort.

Laya and Combined never fall to step 5: both are constrained to click only a box that a local detection pass actually produced. This is why Gemini Flash in Combined mode is given *labels*, never asked to output *pixels*.

## Mode-by-mode data flow

### Laya text (`CuseMode.jev`)

`CompanionManager.submitTextCommand` → ensures `LayaServer` is running → `JevPointerLoop.run`:

1. `engine.localPerceptionTargets(refresh: true)` — fresh CoreML/OCR/AX boxes.
2. `JevGrounding.request` bundles the task, history, and candidates into **one** call to the local `multilingual` checkpoint (`JevClient` → `127.0.0.1:8765/v1/systemone`, served by `laya_systemone.py`, launched from Application Support). Candidates are first ranked by how well their labels match the task, weighting each shared word by how rare it is on screen, so the named control survives the 200-candidate cap. When a few labels clearly match (`focusedShortlist`), Laya chooses among just those; if it answers "none", the same step is asked again with the full list. Measured on Wikipedia with ~80 candidates: "Click English" went from a wrong browser-tab pick (0.33) to the English link (0.92).
3. Laya answers four questions in one round trip: `done`, `absent`, `pick` (which candidate), `kind`. Each candidate is described with its label, source, a screen-region word ("top-left"; global points use AppKit's bottom-left origin) and, for wide YOLO boxes, "(wide text-field shape)". `kind` offers click/double-click/right-click, plus `type_text` right after a click when the task quotes or names text to enter, and `press_enter` right after typing. The typed text is copied from the task, never generated. An explicit `__none__` option lets it say "not on screen" instead of guessing.
4. `JevGrounding.decision` validates the response defensively — malformed probabilities, an invented ID, or a near-tied gesture choice are all rejected or corrected before anything is clicked.
5. The chosen candidate becomes a `PointerActionRequest` and goes to `engine.runPointerAction`, which re-grounds, clicks, and validates the state actually changed.

While typed text is pending, only single clicks are offered, a field-shaped candidate within 0.10 of the top pick wins, the focusing click skips the engine's change check (a caret barely changes the screen; the typing step is validated instead), and Laya's done score is ignored. One-action commands ("Click English") finish after one validated action, and "search for X" tasks once X is typed and Return pressed, because Laya's own done score proved unreliable.

Stops after 12 actions, on the `__none__` choice, on `done ≥ 0.70`, on a target app change, on cancellation, or on an action failure.

**Testing a text mode end to end:** `POST /v1/text-command` with `{"task": "...", "app": "Google Chrome", "mode": "laya"}` runs the same path as the panel; it refuses unless `app` is frontmost, because the run acts on whatever is in front. Poll `GET /v1/text-command` for the outcome and read `GET /v1/action-history` for each click.

### Combined text (`CuseMode.combined`) — new

Its own shortcut (Ctrl+L), but the same text command panel and the same local Laya server (Combined needs Laya running, since Laya matches every click). `CompanionManager.submitTextCommand` branches on `selectedMode` to run `CombinedPointerLoop.run` instead of `JevPointerLoop.run`.

Per step:

1. Fresh local targets, same as Laya.
2. **`GeminiFlashPlanner.plan(...)`** — one `generateContent` REST call to `gemini-3.8-flash`, falling back to `gemini-3.7-flash` when overloaded (`Cuse/Combined/GeminiFlashPlanner.swift`), carrying the task, action history, frontmost app, and every detected element as `{id, label, source, box}` (box is the same `normalizedBox2D` — 0–1000 scale — that the harness already exposes, so no new perception format was introduced). A strict JSON response schema keeps the answer to one `{status, remaining_plan, action, target_id, target_description, text, message}` object; no coordinates are ever in that schema.
   - `status: act` — perform `action` now.
   - `status: done` — the task is already finished.
   - `status: need_screenshot` — labels weren't enough (e.g. icon-only controls); re-plan the same step with a screenshot attached, but only when the user's Screenshots toggle allows it (`engine.screenshots()` returns `ok: false` otherwise, and the loop stops with a clear message rather than silently skipping privacy).
   - `status: impossible` — nothing on screen can advance the task.
3. **For click / double-click / right-click:** Gemini's `target_description` (plus its own `target_id` guess) is handed to Laya as a *single-step* instruction (`CombinedPointerLoop.layaStepInstruction`) — deliberately just this step, not the whole task, so Laya can't wander ahead of the plan. Laya ranks the same detected boxes via the identical `JevGrounding`/`JevClient` path used in Laya-only mode.
   - **Agreement** (Laya's top pick == Gemini's `target_id`, or Gemini named nothing and Laya found one) → click immediately.
   - **Disagreement** → one Gemini re-check: Gemini is shown both candidates (plus a screenshot, requested at this point if not already fetched) and must return `act` with the same action and a `target_id` equal to one of the two, or `impossible`. There is no infinite back-and-forth — this is a single arbitration round, then the loop either clicks or stops.
4. **For type / press_key / keyboard_shortcut / open_app:** no target resolution is needed; the `PointerActionRequest` carries Gemini's `text` field directly (a string to type, a key name, a shortcut like `Cmd+N`, or an app name) and goes straight to the engine's existing targetless workflow-step path.
5. The engine executes and validates the step exactly as it does for Laya and Gemini realtime.

Stops after 15 actions, on `done`/`impossible`, on a malformed plan, on an unresolved target after the disagreement re-check, on a target app change (following the app if Gemini opened a new one with `open_app`), on cancellation, or on an action failure.

**Why a Gemini Flash + Laya loop instead of Gemini alone acting on screenshots:** screenshot-coordinate clicking is comparatively imprecise on dense desktop UIs. Combined mode keeps Gemini's language-level reasoning about *what* to do, but keeps the actual pointer placement pinned to a real, locally-detected box — the same guarantee Laya-only mode already made. The one-round arbitration step exists because Gemini's guess and Laya's guess can each be wrong in different ways (Gemini can misread a description as pointing at a similar label; Laya can rank a decoy above the true match), and requiring one to defer to a *specific alternative* rather than retrying from scratch keeps the step bounded and auditable.

### Gemini realtime (`CuseMode.gemini`)

Unchanged. Ctrl+Option opens a `GeminiLiveSession` (WebSocket, `Cuse/Voice/GeminiLiveClient.swift`) with microphone audio and, when the Screenshots toggle is on, screen images. Gemini calls one tool per turn — a desktop workflow action or the Apple Notes convenience action — which is submitted through the same `WorkflowRunner`/`ActionExecutor` path as the text modes.

## Mode selection and shortcuts

- **`CuseMode`** (`Cuse/Core/CuseMode.swift`) is the single source of truth for each mode's title, picker label, icon, summary, privacy text, shortcut, Keychain key name, and permission rule. UI never hardcodes mode names or shortcuts; it reads these properties.
- **Settings → Models** (`CuseSettingsView` → `ProviderSetupView` → `ModeSelectionView`) renders one card per `CuseMode.allCases`, so Laya, Combined, and Gemini all appear there automatically. Below the picker, `ProviderKeyCard` shows "Ready locally" for Laya and the shared Gemini key field for Gemini and Combined. Onboarding reuses the same `ModeSelectionView` and `ProviderKeyCard`.
- **`CompanionManager.setSelectedMode`** cancels any running text command or voice session, persists the choice (`CuseDefaults.selectedMode`), and refreshes key status.
- **Hotkeys:** `GlobalTextCommandShortcutMonitor` publishes a `TextCommandShortcut` (`.laya` for Ctrl+K, `.combined` for Ctrl+L). `CompanionManager.openTextCommand(for:)` switches `selectedMode` to match the shortcut and then opens the panel, so either text mode can be started without visiting Settings. Ctrl+Option still starts Gemini realtime only when Gemini is selected. The menu bar button (`openSelectedMode`) and the radial chooser's Type option open whichever text mode is selected.
- **Launching:** `Start Cuse.app` in the repo only relaunches the newest existing Xcode build in DerivedData; it does not compile. After changing source, run once from Xcode (Cmd+R) so the launcher picks up the new build.

## Shared engine layer

- **`CuseEngine`** (`Cuse/Core/CuseEngine.swift`) is the facade every mode and the local harness call through: `observe()`, `localPerceptionTargets(refresh:)`, `groundTarget(...)`, `runPointerAction(...)`, `screenshots()`. It owns nothing about *which* mode is asking — it just grounds, executes, and reports.
- **`WorkflowRunner`** owns pause/resume, per-operation cancellation tokens, target resolution against the freshest perception pass, and the post-action validation that confirms a click actually changed something before the loop calls it done.
- **`ActionExecutor` / `CuseActionDriver`** deliver the literal CUA (computer-use-agent) input — the only place that touches the cursor and keyboard.
- **`LocalPerceptionTargetCache`** holds the current frame's detected boxes (`id`, `label`, `source`, `confidence`, `screenshotBox`, `normalizedBox2D`, `globalCenter`/`globalBox`, `displayFrame`). Both `JevGrounding` (Laya) and `GeminiFlashPlanner` (Combined) build their candidate lists from this same cache, so a box Laya can click is exactly a box Gemini can describe.
- **`LocalTargetContinuity`** re-validates a previously chosen target against small bounds changes after a refresh, so neither loop clicks a stale location.
- **Localhost harness** (`Cuse/Harnesses/CuseHarnessServer.swift`, `127.0.0.1:19474`) exposes the same engine to developer clients; see [docs/cuse-agent-contract.md](docs/cuse-agent-contract.md).

## Credentials and permissions

- **Laya** needs no API key — `laya_systemone.py` serves the on-device `multilingual` checkpoint from `~/Library/Application Support/Cuse/laya`, launched by `LayaServer` and reached over loopback only.
- **No repeated password prompts.** `KeychainStore` decrypts each key at most once per launch and keeps it in memory; "is a key saved?" checks use an attribute-only lookup that never decrypts. After the first successful read, the item is re-saved (delete then add, never update) so its access list trusts the current Team-signed build, and later launches and rebuilds read it silently.
- **Gemini realtime and Combined share one Keychain entry** (`geminiAPIKey`, `Cuse/Utilities/KeychainStore.swift`). `CuseMode.requiresAPIKey` is `true` for both, and `CuseMode.keyName` returns the same key name for both, so saving the key once in **Settings → Models** unlocks both modes. There is no environment variable, sibling-project, or hosted-key fallback — only macOS Keychain.
- **Permissions**: Accessibility and Screen Recording/Screen Content are required for Laya and Combined (both click and both perceive the screen locally); microphone is required only for Gemini realtime voice. `CuseMode.permissionsReady(desktop:microphone:)` encodes this once and is shared by onboarding, Settings, and the menu bar panel.
- **Screenshots toggle**: governs remote images for Gemini realtime and for Combined's `need_screenshot` fallback. It never affects Laya, which has no screenshot path at all.

## Where new code should go

Following the existing convention (`Cuse/Voice` for Gemini realtime networking, `Cuse/Jev` for Laya's client/loop/UI): **`Cuse/Combined`** holds Combined-mode-only code — the Gemini Flash planner (`GeminiFlashPlanner.swift`) and the step loop that coordinates Gemini and Laya (`CombinedPointerLoop.swift`). It reuses `Cuse/Jev`'s `JevClient`/`JevGrounding`/`JevStepPanelView` rather than duplicating them, since Combined's click-matching step *is* a Laya call. Execution, validation, and pauses stay in `Cuse/Workflow` and `Cuse/Actions` — Combined does not introduce a second execution path, only a second planner in front of the existing one.

## Testing

`scripts/test-jev.sh` extracts the pure, network-free logic — `JevClient`/`JevGrounding`/`LocalTargetContinuity`/`CuseMode`/`KeychainStore` plus `GeminiFlashPlanner`'s request-building and response-validation code — into a throwaway SwiftPM package and runs `CuseTests/JevTests.swift` against it. This lets decision logic (candidate deduplication, tie-breaking, schema validation, invented-ID rejection, mode/permission rules) be verified without building, signing, or launching the app, and without any network access or API key.
