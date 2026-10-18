# Release Scripts

## `release.sh` — Ship a new version of Cuse

Automates the full release pipeline: build → sign → DMG → notarize → Sparkle appcast → GitHub Release.

### Quick start

```bash
# Auto-bumps version and build number from the latest GitHub Release
./scripts/release.sh
```

The script checks GitHub for the latest release (e.g. `v1.5`, build 6) and automatically bumps to `v1.6`, build 7. You'll see a confirmation prompt before anything runs.

### Override version or build

```bash
# Set a specific marketing version (auto-bumps build)
./scripts/release.sh 2.0

# Set both marketing version and build number
./scripts/release.sh 2.0 10
```

### Safety

- **Duplicate detection**: If the tag already exists on GitHub, the script exits with an error and suggests what to do.
- **Confirmation prompt**: Shows the version, build, and previous release before proceeding. Press `y` to continue.

### What it does

1. Fetches the latest release from GitHub to determine version + build
2. Archives the app via `xcodebuild`
3. Exports a signed `.app` with Developer ID
4. Creates a DMG with the drag-to-Applications background
5. Notarizes the DMG with Apple (Gatekeeper compliance)
6. Signs the DMG with the Sparkle EdDSA key
7. Generates `appcast.xml` for Sparkle auto-updates
8. Creates a GitHub Release with the DMG attached
9. Pushes the updated `appcast.xml` to the releases repo

### One-time setup (prerequisites)

Run these once on the machine you'll release from:

1. **Apple Developer ID Application certificate** — verify with:
   ```bash
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```
   If empty: Xcode → Settings → Accounts → your Apple ID → Manage Certificates → **+** → Developer ID Application.

2. **Homebrew tools**:
   ```bash
   brew install create-dmg gh
   ```

3. **GitHub CLI auth**:
   ```bash
   gh auth login
   ```

4. **Apple notarization credentials** (stored once in Keychain):
   ```bash
   xcrun notarytool store-credentials "AC_PASSWORD" \
       --apple-id YOUR_APPLE_ID_EMAIL \
       --team-id YOUR_10_CHAR_TEAM_ID \
       --password YOUR_APP_SPECIFIC_PASSWORD
   ```
   Generate an app-specific password at [appleid.apple.com](https://appleid.apple.com) → Sign-In and Security → App-Specific Passwords. Find your team ID at [developer.apple.com/account](https://developer.apple.com/account) → Membership Details.

5. **Build the project in Xcode at least once** so SPM downloads Sparkle and its CLI tools become available.

6. **Sparkle EdDSA key** — generate once after step 5:
   ```bash
   SPARKLE_BIN=$(find ~/Library/Developer/Xcode/DerivedData/Cuse*/SourcePackages/artifacts/sparkle/Sparkle/bin -maxdepth 0 | head -1)
   "$SPARKLE_BIN/generate_keys"
   ```
   Copy the printed **public** key. Open `Cuse.xcodeproj` and replace the placeholder
   `INFOPLIST_KEY_SUPublicEDKey = "REPLACE_WITH_SPARKLE_PUBLIC_KEY_FROM_generate_keys"`
   in the project's build settings (search for `SUPublicEDKey` in Build Settings — both Debug and Release configs).

7. **Releases repo** — create a public GitHub repo named `cuse-releases` (or whatever you set as `GITHUB_REPO` in `release.sh`). The script clones it, pushes the new `appcast.xml`, and creates Releases there. An empty repo with a README is enough.

8. **Update repo URL if needed** — open `release.sh` and change `GITHUB_REPO=` if your releases repo isn't `muneebkhan08/Cuse`.

After all 8 steps, the first release runs end-to-end with `./scripts/release.sh`.
