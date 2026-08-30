# Development

Build, test, packaging and release notes for Mana. For what the app does and
how to install it, see [README.md](README.md).

## Layout

```
Sources/
  App/            ManaApp (@main), AppDelegate, StatusBarController, UsageCoordinator
  Panel/          PanelWindow (NSPanel), HotZoneMonitor, PanelView, RingView, DetailCardView
  Providers/      UsageProvider protocol, ServiceUsage model, Claude and Codex providers
  Storage/        KeychainStore, UsageSnapshotCache
  Settings/       AppSettings, SettingsView
  Notifications/  NotificationManager, threshold tracking
Tests/ManaTests/  XCTest target
packaging/homebrew/mana.rb   Homebrew cask (source of truth, copied into the tap)
scripts/          package-dmg.sh, release.sh
```

`project.yml` (XcodeGen) defines the `Mana` app target — bundle id
`com.manabar.Mana`, macOS 13+, `LSUIElement = true`, sandbox off — and the
`ManaTests` unit-test target. The generated `Mana.xcodeproj` is gitignored.

## Build and test

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project Mana.xcodeproj -scheme Mana -configuration Debug build
xcodebuild -project Mana.xcodeproj -scheme Mana -configuration Debug test -destination 'platform=macOS'
```

Note that `xcodebuild test` launches the app from DerivedData as the test host,
and that instance can outlive the run — if two Mana icons show up in the menu
bar, one of them is it (`pkill -f 'DerivedData.*Mana'`).

There is also an opt-in smoke test that hits the real APIs with whatever CLI
login exists on the machine. It is skipped by default and can prompt for
Keychain access, so never run it unattended:

```bash
MANA_LIVE_SMOKE=1 xcodebuild -project Mana.xcodeproj -scheme Mana test -destination 'platform=macOS'
```

## Packaging

```bash
scripts/package-dmg.sh
```

Builds Release, code-signs `Mana.app`, and packages it into
`dist/Mana-<version>.dmg` plus a `.sha256`, using only `hdiutil` and
`codesign`. Intermediate output lives in `dist/work/`; `dist/` is gitignored.

Without `MANA_SIGN_IDENTITY`, the signing identity is chosen in this order:

1. the first **Developer ID Application** identity in the keychain — the only
   kind that produces a `.dmg` other people can open cleanly;
2. the first **Apple Development** identity — fine for running the build
   locally, refused by Gatekeeper everywhere as if downloaded;
3. ad-hoc (`-`) as a last resort, where nothing about the signer is verifiable.

The script ends with `spctl -a -t open --context context:primary-signature`,
which simulates the as-if-downloaded assessment. With anything short of a
notarized Developer ID signature it reports **rejected**, including on the
machine that produced the build — that is the expected result today, not a bug
in the script.

| Variable | Purpose |
|----------|---------|
| `MANA_SIGN_IDENTITY` | Force a codesign identity (name or SHA-1), skipping the lookup above. |
| `MANA_NOTARY_PROFILE` | Name of a `notarytool store-credentials` profile. When unset, notarization is skipped — not an error. |

### Notarization

Requires a paid Apple Developer Program membership and a **Developer ID
Application** certificate; an Apple Development certificate does not qualify.
Store the credentials once, then pass the profile name:

```bash
xcrun notarytool store-credentials "mana-notary" \
  --apple-id "<apple id email>" \
  --team-id "<TEAMID>" \
  --password "<app-specific password from appleid.apple.com>"

MANA_NOTARY_PROFILE=mana-notary scripts/package-dmg.sh
```

The script then submits the image with `notarytool submit --wait` and staples
the ticket. Once that works, drop the `postflight` block from
`packaging/homebrew/mana.rb` — it exists only to strip the quarantine attribute
an unnotarized build cannot survive.

## Releasing

```bash
scripts/release.sh --dry-run   # build, then print what would be published
scripts/release.sh             # tag, publish, point the cask at the new build
```

Bump `CFBundleShortVersionString` and `MARKETING_VERSION` in `project.yml`
first and commit — the script takes the version from the built app rather than
inventing one, and refuses to run on a dirty tree, on a commit that is not
pushed, or when the tag or release already exists.

It builds the image, tags `v<version>`, creates the GitHub Release with the
`.dmg` and its checksum, rewrites the `version`/`sha256` lines in
`packaging/homebrew/mana.rb`, then copies the cask into the tap checkout and
pushes it. `MANA_TAP_DIR` overrides where that checkout is; by default it is
the directory `brew tap TinyFrontier/tap` creates.

The cask has to live in [its own repository](https://github.com/TinyFrontier/homebrew-tap):
Homebrew requires taps to be named `homebrew-<name>`, so it cannot sit here.
The copy under `packaging/homebrew/` is the source of truth — edit it here, not
in the tap.

## The Accessibility grant during development

macOS remembers the Accessibility (TCC) grant against the app's **code
signature**, not its name or path. Debug builds are ad-hoc signed
(`CODE_SIGN_IDENTITY = "-"` in `project.yml`), and an ad-hoc signature's
designated requirement pins the binary's hash — so **every rebuild is a
different app** as far as TCC is concerned. System Settings keeps showing
"Mana" as ON while `AXIsProcessTrusted()` returns `false` for the build you
just made.

Symptom: onboarding says "Not granted" even though the toggle is on.

Fixes, in order of preference:

1. Reset and re-grant — fast, works every time:

   ```bash
   tccutil reset Accessibility com.manabar.Mana
   ```

2. Sign with a stable identity, and the grant survives rebuilds. Create a
   self-signed code-signing certificate once (Keychain Access → Certificate
   Assistant → *Create a Certificate…*, type *Code Signing*, name it
   `Mana Dev`), then:

   ```bash
   xcodebuild -project Mana.xcodeproj -scheme Mana -configuration Debug \
     CODE_SIGN_IDENTITY="Mana Dev" build
   ```

3. Run from a stable path — a copy in `/Applications` and a copy in DerivedData
   are separate entries to TCC.

The same signature rule governs the Keychain grant for reading Claude Code's
credentials, which is why a rebuilt ad-hoc Debug build asks for permission
again while the released, certificate-signed build does not.

Two things make this less painful:

- Mana re-checks the grant while running — `AccessibilityPermissionMonitor`
  polls every 2s *only while permission is missing* and stops once it is
  granted — so granting no longer requires a restart. There is a "Recheck"
  button next to the status row.
- Hover-to-show does not actually depend on the grant: global *mouse-move*
  monitoring works without it, only key-event monitoring is gated. The
  permission is still worth granting for reliability across Spaces and
  full-screen apps, and the menu-bar "Show/Hide Panel" item is always there as
  a fallback.
