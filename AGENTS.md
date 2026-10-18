# Cuse — Agent Instructions

This file is the source of truth for coding agents; CLAUDE.md is a symlink.

## Product

macOS 14.2+ menu bar-only SwiftUI/AppKit app (`LSUIElement=true`). Three provider modes ship together on `main`:

- **Gemini realtime**: Ctrl+Option toggles a voice session. Audio and optional screenshots go directly to Gemini using the user's Keychain key. One tool per user turn: a single desktop workflow action or the existing Apple Notes convenience action.
- **Laya text**: Ctrl+K opens the command panel. The local `laya-multilingual` checkpoint in `~/Library/Application Support/Cuse/laya` classifies locally detected screen labels and locations. Laya selects click/double-click/right-click targets, not prose or pixels. Candidates are ranked by rarity-weighted label overlap with the task before the 200 cap; when a few labels clearly match, Laya first chooses among that focused shortlist and falls back to the full list if it answers none. Descriptions carry a screen-region word (AppKit global points: largest y is the top) and a "wide text-field shape" hint for wide YOLO boxes. Laya may type text only when it is quoted or named in the user's own task ("search for X", "type 'X'"), only right after a click, then press Return; while such text is pending it single-clicks, prefers a field-shaped target within 0.10 of its top pick, skips the change check for that focusing click, and ignores its own done score. It acts on the top-ranked target without minimum probability or absent-score cutoffs. One-action commands finish after one validated action and "search for X" tasks after typing plus Return. Its bounded loop stops on an explicit none choice, task completion, malformed responses, cancellation, action rejection/pause/failure, or 12 actions, with a final observation after the last action.

- **Combined text**: Ctrl+L opens the command panel and selects Combined. Every step, Gemini Flash (`gemini-3.8-flash`, falling back to `gemini-3.7-flash` when overloaded, REST `generateContent` with the Gemini Keychain key) plans one action from the local CoreML/OCR/AX labels; if labels are not enough it re-plans that step with a cursor-screen screenshot, only when Screenshots is on. Gemini never returns coordinates. For click/double-click/right-click, Laya ranks the detected boxes for Gemini's target description; agreement acts immediately, disagreement triggers one Gemini re-check that must choose Gemini's or Laya's element or stop. Type, key, shortcut and open-app actions go through the same engine without a target. Stops on done/impossible, malformed plans, unresolved targets, cancellation, action failure, or 15 actions.

Laya is the default selected mode. Onboarding is Choose mode → Save Gemini’s API key only if Gemini or Combined is selected (they share it) → Grant its permissions; only Gemini voice requires microphone access. Laya needs no key. The previous onboarding flag is migrated to a new mode-setup completion flag so existing users also choose a mode. Settings → Models shows the selector and Gemini’s key input when Gemini or Combined is selected. Gemini’s key is stored only in macOS Keychain; no environment, sibling project, or hosted-key fallback. The UI must report Keychain errors accurately.

No Claude/Hermes integration, separate Flash Lite matcher, image-generation service, recording/video pipeline, or Worker proxy is bundled. Do not reintroduce them without an explicit user request.

## Architecture

- `CompanionManager` persists the selected mode, initializes Gemini only when used, starts the local Laya server for text commands, gates mode-specific shortcuts, and coordinates hotkeys, provider sessions, focus highlight, permissions, and overlay state. It owns the cancellable Laya task and prevents overlapping text/voice runs.
- `CuseEngine` is the shared facade for perception, exact targets, workflow submission, action history, and localhost harness operations. `WorkflowRunner` owns pauses, per-operation tokens, target resolution, and post-action checks. `ActionExecutor`/`CuseActionDriver` deliver CUA input. Never bypass these boundaries.
- Ground exact local IDs/marks first, then AX, browser DOM/CDP, local CoreML/OCR, and finally Gemini screenshot coordinates. Laya never invents coordinates and never walks stale alternative rankings after a failed action.
- Laya runs local detection while active without changing the user's persisted Accurate Grounding setting. Its command panel freezes position during execution; Escape/Stop cancels the task and active workflow. Text decisions go to `127.0.0.1:8765`, which serves the multilingual checkpoint from Application Support (`Cuse/laya`, falling back to a pre-rebrand `TipTour/laya` install when no Cuse install exists).
- Ctrl+Shift paints focus context for Gemini. Ctrl+Option+Command is a Speak/Type/Highlight input chooser, not an extra model mode.
- Auto-click controls action delivery; Gemini supports point-only guidance, while Laya requires auto-click. CUA's toggle gates all desktop actions. Screenshots controls remote images, not local perception. Microphone is needed only for Gemini.
- AX is enabled for Electron on app activation. Preserve batched AX reads, messaging timeouts, target app pinning, clipboard/selected-range protections, and event-driven detection refreshes.
- The localhost harness (`127.0.0.1:19474`) exposes the engine to developer clients. `/v1/agent-contract` is canonical. Debug `POST /v1/text-command` ({task, app, mode}) runs a whole Laya/Combined command only when `app` is frontmost; poll `GET /v1/text-command`. Preserve trace IDs, single-action workflow limits, and explicit deterministic `/v1/tasks` sequences.
- Portable app instructions live in `Cuse/Skills/**/SKILL.md`; precedence is user overrides, project skills, then bundled skills. General documentation belongs outside the app target.

## Key files

| File | Purpose |
| --- | --- |
| `Cuse/App/CompanionManager.swift` | Shared state, provider coordination, hotkeys, highlight and detection lifecycle |
| `Cuse/Perception/LocalTargetContinuity.swift` | Matches the same label/source/display across small detection bounds changes before execution (~20 lines) |
| `Cuse/Core/CuseMode.swift` | Laya-first mode defaults, key/shortcut metadata and permission requirements (~40 lines) |
| `Cuse/Core/CuseEngine.swift` | Grounding, execution, validation and local harness facade |
| `Cuse/Laya/LayaServer.swift` | Launches the local multilingual Laya server from Application Support (~150 lines) |
| `Cuse/Laya/laya_systemone.py` | Jev-compatible `/v1/systemone` server pinned to `laya-multilingual` (~220 lines) |
| `Cuse/Jev/JevClient.swift` | Localhost client for that Laya server |
| `Cuse/Jev/JevGrounding.swift` | Relevance-ranked and shortlisted candidates, typing/Return options, completion rules, validated decisions (~435 lines) |
| `Cuse/Jev/JevPointerLoop.swift` | Cancellable Laya action loop with shortlist fallback and typing steps (~240 lines) |
| `Cuse/Jev/JevStepPanelView.swift` | Decision progress in the text panel |
| `Cuse/Combined/GeminiFlashPlanner.swift` | Gemini Flash per-step planner: pure request/response validation plus REST client (~375 lines) |
| `Cuse/Combined/CombinedPointerLoop.swift` | Combined loop: Gemini plans, Laya matches the box, engine acts, disagreement re-check (~350 lines) |
| `Cuse/Voice/GeminiLiveSession.swift` | Realtime session, microphone, screenshots and tool callbacks |
| `Cuse/Voice/GeminiLiveClient.swift` | Gemini WebSocket protocol and tool declarations |
| `Cuse/UI/ProviderSetupView.swift` | The two Keychain key cards |
| `Cuse/UI/CompanionPanelView.swift` | Compact mode hints, permissions and action controls |
| `Cuse/UI/CuseSettingsView.swift` | Models, desktop actions, privacy, permissions and advanced options |
| `Cuse/UI/TextCommandPanelManager.swift` | Cursor-following, resizable command panel |
| `Cuse/UI/TextCommandPanelView.swift` | Laya input, stop control and results |
| `Cuse/Utilities/KeychainStore.swift` | Device-local provider credential storage |

See `docs/source-layout.md` for the remaining directory responsibilities.

## Build and verification

Open `Cuse.xcodeproj`, select Cuse, set the signing team, and build/run in Xcode.

**Do NOT run `xcodebuild` from the terminal** — it invalidates TCC permissions and the app will need to re-request screen recording/accessibility access. Pure Swift parsing/typechecking and isolated tests are permitted without replacing or launching the installed app. Run `scripts/test-jev.sh` for the JEV decision suite.

Known non-blocking Swift 6 concurrency and deprecated `onChange` warnings must not be fixed as incidental cleanup.

## Code Style & Conventions

### Variable and Method Naming

IMPORTANT: Follow these naming rules strictly. Clarity is the top priority.

- Be as clear and specific with variable and method names as possible
- **Optimize for clarity over concision.** A developer with zero context on the codebase should immediately understand what a variable or method does just from reading its name
- Use longer names when it improves clarity. Do NOT use single-character variable names
- Example: use `originalQuestionLastAnsweredDate` instead of `originalAnswered`
- When passing props or arguments to functions, keep the same names as the original variable. Do not shorten or abbreviate parameter names. If you have `currentCardData`, pass it as `currentCardData`, not `card` or `cardData`

### Code Clarity

- **Clear is better than clever.** Do not write functionality in fewer lines if it makes the code harder to understand
- Write more lines of code if additional lines improve readability and comprehension
- Make things so clear that someone with zero context would completely understand the variable names, method names, what things do, and why they exist
- When a variable or method name alone cannot fully explain something, add a comment explaining what is happening and why

### Swift/SwiftUI Conventions

- Use SwiftUI for all UI unless a feature is only supported in AppKit (e.g., `NSPanel` for floating windows)
- All UI state updates must be on `@MainActor`
- Use async/await for all asynchronous operations
- Comments should explain "why" not just "what", especially for non-obvious AppKit bridging
- AppKit `NSPanel`/`NSWindow` bridged into SwiftUI via `NSHostingView`
- All buttons must show a pointer cursor on hover
- For any interactive element, explicitly think through its hover behavior (cursor, visual feedback, and whether hover should communicate clickability)

### Do NOT

- Do not add features, refactor code, or make "improvements" beyond what was asked
- Do not add docstrings, comments, or type annotations to code you did not change
- Do not try to fix the known non-blocking warnings (Swift 6 concurrency, deprecated onChange)
- Do not run `xcodebuild` from the terminal — it invalidates TCC permissions

## Git Workflow

- Branch naming: `feature/description` or `fix/description`
- Commit messages: imperative mood, concise, explain the "why" not the "what"
- Do not force-push to main

## Self-Update Instructions

<!-- AI agents: follow these instructions to keep this file accurate. -->

When you make changes to this project that affect the information in this file, update this file to reflect those changes. Specifically:

1. **New files**: Add new source files to the "Key Files" table with their purpose and approximate line count
2. **Deleted files**: Remove entries for files that no longer exist
3. **Architecture changes**: Update the architecture section if you introduce new patterns, frameworks, or significant structural changes
4. **Build changes**: Update build commands if the build process changes
5. **New conventions**: If the user establishes a new coding convention during a session, add it to the appropriate conventions section
6. **Line count drift**: If a file's line count changes significantly (>50 lines), update the approximate count in the Key Files table

Do NOT update this file for minor edits, bug fixes, or changes that don't affect the documented architecture or conventions.
