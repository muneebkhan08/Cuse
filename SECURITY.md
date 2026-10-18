# Security Policy

Cuse can see your screen and control your Mac, so security reports are taken seriously.

## Reporting a vulnerability

Please **do not open a public issue.** Use GitHub's private reporting instead:

**[Report a vulnerability →](https://github.com/muneebkhan08/Cuse/security/advisories/new)**

Include what you found, how to reproduce it, and the impact you expect. You'll get an acknowledgement as soon as possible, and a fix or mitigation plan once the report is confirmed.

## Scope

Especially interesting:

- Ways for web pages, documents or other on-screen content to make Cuse take actions the user didn't ask for (prompt injection through screen text).
- The localhost harness (`127.0.0.1:19474`) or the Laya server (`127.0.0.1:8765`) being reachable from other machines or abused by other local processes.
- Leaks of the Gemini API key outside the macOS Keychain.
- Screenshots or audio being sent anywhere other than the configured provider, or when the user turned them off.

## Supported versions

Only the latest release and `main` receive security fixes.
