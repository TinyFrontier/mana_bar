# Mana — context for future sessions

## What this is

Mana (ManaBar) is a native macOS accessory app: a panel showing usage of
AI-service subscription limits (Claude, ChatGPT, ...) that lives hidden
behind the right screen edge and slides out on cursor hover. No Dock icon;
lives in the menu bar. Distributed outside the App Store (signed +
notarized .dmg), not sandboxed — see spec for why.

## Принятые решения

- **2026-08-28 — модель авторизации.** Получение данных о лимитах идёт по пути
  **openusage**: приложение переиспользует OAuth-токены, уже выпущенные
  установленными у пользователя CLI-инструментами (Claude Code CLI / Claude
  Desktop для Claude, Codex CLI для ChatGPT), а не browser-cookie и не
  ручной ввод session-токена. Cookie-модель (референсы Usage4Claude/
  AIQuotaBar) рассмотрена и отклонена. Подробности, эндпоинты и разбор
  референса — `docs/research/openusage-core.md`; закреплено в
  `docs/ТЗ-Mana.md` §4.1–4.3.

## Source of truth

- **Spec**: [`docs/ТЗ-Mana.md`](docs/ТЗ-Mana.md) — read this first for any
  behavioral question (panel show/hide mechanics, thresholds, settings,
  acceptance criteria, out-of-scope items).
- **Core research**: `docs/research/openusage-core.md` — findings on
  **openusage** (MIT), the reference open-source implementation the real
  `ClaudeProvider`/`ChatGPTProvider` logic should draw on: OAuth-token
  auth store, usage-client endpoints, and refresh/retry flow per provider.
- **Design spec**: `docs/design/design-spec.md` — visual/interaction spec
  (colors, spacing, animation timing) backing `docs/prototype/`.

## Structure

```
Sources/
  App/            ManaApp (@main), AppDelegate, StatusBarController
  Panel/          PanelWindow (NSPanel), HotZoneMonitor, PanelView, RingView, DetailCardView
  Providers/      UsageProvider protocol, ServiceUsage model, ClaudeProvider, ChatGPTProvider
  Storage/        KeychainStore
  Settings/       AppSettings, SettingsView
  Notifications/  NotificationManager
Tests/ManaTests/  XCTest target (smoke test currently)
```

`project.yml` (XcodeGen) defines the `Mana` app target (bundle id
`com.manabar.Mana`, macOS 13.0+, `LSUIElement = true`, sandbox off,
`SWIFT_VERSION = 5.0`) and the `ManaTests` unit test target. The
`Mana.xcodeproj` it generates is gitignored — regenerate after cloning or
after editing `project.yml`.

## Build & test

```bash
xcodegen generate
xcodebuild -project Mana.xcodeproj -scheme Mana -configuration Debug build
xcodebuild -project Mana.xcodeproj -scheme Mana -configuration Debug test -destination 'platform=macOS'
```

## Status

**MVP implemented (2026-08-29).** All layers are real, ~160 unit tests:

- **Providers** (`Sources/Providers/`): Claude (Keychain Claude Code /
  `~/.claude/.credentials.json` / Claude Desktop safe-storage) and Codex
  (`~/.codex/auth.json` / "Codex Auth" keychain) auth stores, both with a
  silent vs interactive split; usage clients + mappers; 401/403→refresh→
  retry-once; 429/Retry-After. The frozen data contract lives in
  `UsageProvider.swift` / `ServiceUsage.swift` — change it only
  deliberately, both layers depend on it.
- **Silent Keychain rule**: legacy login-keychain items ignore
  `LAContext.interactionNotAllowed`; the only honored switch is
  `SecKeychainSetUserInteractionAllowed(false)` — see `withKeychainGate`
  in `KeychainStore.swift`. `UsageError.keychainAccessDenied` = item
  exists but needs a one-time interactive grant (Refresh Now → Always
  Allow).
- **Panel** (`Sources/Panel/`): hot-zone monitor (Accessibility-gated,
  manual Show/Hide fallback in the menu), non-activating NSPanel over
  fullscreen, rings + detail card matching `docs/design/design-spec.md`.
- **App** (`Sources/App/`): `UsageCoordinator` (independent parallel
  polling, last-good snapshot on failure, 60s failure cooldown, 15s fetch
  timeout, wake refresh, pause/resume), onboarding, credential-source
  status.
- **Settings/Notifications**: persisted `AppSettings` wired live;
  UNUserNotificationCenter thresholds with per-window cooldown.

Known TODOs: left screen edge (Settings control disabled), explicit
monitor picker, deep multi-monitor/Spaces handling, .dmg
packaging/signing/notarization.
