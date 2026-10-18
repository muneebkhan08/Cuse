# Changelog

All notable changes to Cuse are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed
- Rebranded the app from **TipTour** to **Cuse**: app name, bundle identifier (`com.muneebkhan.cuse`), Xcode project, targets, source folders, Swift types, docs and launcher.
- Logs and the Laya install now live under `~/Library/Application Support/Cuse/`. An existing Laya install under the old `TipTour/laya` folder keeps working until a new one is installed.
- User skill overrides moved from `~/.tiptour/skills` to `~/.cuse/skills`.
- Sparkle update feed now points at this repository's `appcast.xml`.

### Notes for existing TipTour users
- Because the bundle identifier changed, macOS asks again for Accessibility, Screen Recording and (for Gemini voice) Microphone access, and the Gemini API key must be pasted once more.

### Added
- Three provider modes: **Laya** on-device text commands (Ctrl+K), **Combined** Gemini Flash planning + Laya grounding (Ctrl+L), and **Gemini realtime** voice (Ctrl+Option).
- Contributor docs, issue/PR templates, security policy and CI for the decision test suite.
