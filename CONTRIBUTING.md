# Contributing to Cuse

Thanks for helping make Cuse — the open-source AI cursor agent for macOS — better. This guide gets you from clone to pull request.

## Ground rules

- **Read [AGENTS.md](AGENTS.md) first.** It is the source of truth for architecture, naming and conventions (for humans and coding agents alike).
- **Don't run `xcodebuild` from the terminal.** Building outside Xcode replaces the signed app and invalidates its macOS Screen Recording and Accessibility permissions. Build and run from Xcode.
- **Every desktop action goes through the engine:** `CuseEngine` → `WorkflowRunner` → `ActionExecutor` / `CuseActionDriver`. Never post input events directly.
- **Clarity over cleverness.** Long, specific names (`originalQuestionLastAnsweredDate`, not `answered`). Comments explain *why*.
- **Scope stays tight.** Fix what the PR is about; leave the known Swift 6 concurrency and deprecated `onChange` warnings alone.

## Setup

1. macOS 14.2+ and a current Xcode (Swift 6 toolchain).
2. Clone and open the project:
   ```bash
   git clone https://github.com/muneebkhan08/Cuse.git
   ```
   ```bash
   open Cuse/Cuse.xcodeproj
   ```
3. Select the **Cuse** scheme, set your signing team, then **Run**.
4. Grant the permissions the selected mode asks for (Accessibility, Screen Recording, and Microphone only for Gemini voice).

## Tests

The Laya / Combined decision suite runs as a standalone Swift package and never touches the installed app:

```bash
scripts/test-jev.sh
```

CI runs the same script on every push and pull request.

## Branches & commits

- Branch from `main` as `feature/short-description` or `fix/short-description`.
- Commit messages are imperative and explain the *why*: `Prefer field-shaped targets before typing`.
- Open a pull request against `main`; CI must be green before merge. Never force-push `main`.

## Reporting bugs and security issues

- Bugs and ideas: use the [issue templates](https://github.com/muneebkhan08/Cuse/issues/new/choose).
- Security problems: report privately — see [SECURITY.md](SECURITY.md).

By contributing you agree that your contributions are licensed under the [MIT License](LICENSE) and that you'll follow the [Code of Conduct](CODE_OF_CONDUCT.md).
