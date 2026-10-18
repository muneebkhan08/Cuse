## What & why

<!-- What does this change, and why is it needed? Link any issue: Closes #123 -->

## How it was verified

- [ ] `scripts/test-jev.sh` passes
- [ ] Built and ran Cuse from Xcode (not terminal `xcodebuild`)
- [ ] Tried the affected mode(s) on a real app: <!-- e.g. Laya in Safari -->

## Checklist

- [ ] Names are clear and specific (see "Code Style" in [AGENTS.md](../AGENTS.md))
- [ ] Every action still goes through `CuseEngine` → `WorkflowRunner` → `ActionExecutor`
- [ ] Docs updated if behaviour, shortcuts or architecture changed
