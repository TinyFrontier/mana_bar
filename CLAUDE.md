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

**Setup phase complete.** Every file under `Sources/` is a compiling stub
(doc-commented with what it should eventually do and a `TODO`) except
`StatusBarController`, which is minimally functional (menu bar icon + Open
Settings / Refresh Now / Pause / Quit items) since a bare status item is
needed for the app to be usable at all. `ClaudeProvider`/`ChatGPTProvider`
intentionally `fatalError` in `fetchUsage()` — inert until wired up, no
current code path calls them. **Real logic (hot-zone tracking, panel
animation, provider networking, Keychain, notifications, settings
persistence) is the next phase**, not yet started.
