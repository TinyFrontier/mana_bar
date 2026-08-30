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

- **2026-08-29 — write-back ротации только в файлы.** Keychain-записи CLI
  (`Claude Code-credentials`, `Codex Auth`) Mana **читает, но не переписывает**:
  `SecItemUpdate` из чужого бинарника пересобирает ACL/partition list записи
  вокруг того, кто писал, `/usr/bin/security` выпадает из доверенных, и `claude`
  начинает при каждом чтении просить пароль login-keychain. Точка входа —
  `allowsRotationWriteBack` в `ClaudeAuthStore.swift` / `CodexAuthStore.swift`;
  не расширяй его обратно на `.keychain`. Уточнение закреплено в
  `docs/ТЗ-Mana.md` §4.2 (отменяет прежнее «обратно в тот же источник»).

- **2026-08-30 — Cursor: рефреш только реактивный.** Access-token Cursor несёт
  `exp`, который его же API игнорирует: наблюдался токен, просроченный по `exp`
  почти на два года и при этом успешно отвечающий на
  `GetCurrentPeriodUsage`. Превентивный рефреш по `exp` тратил refresh-токен на
  каждый опрос и выдавал `sessionExpired` для рабочего логина. Токен
  используется как есть, рефреш — только по 401/403 (`ProviderAuthRetry`);
  не возвращай проверку `exp` в `CursorProvider`.

## Source of truth

> Note for anyone reading this in the public repository: `docs/` is
> gitignored — the spec, research and design notes are local-only, so the
> links below resolve on a maintainer's machine, not on GitHub.

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
  Providers/      UsageProvider protocol, ServiceUsage model, Claude/ChatGPT/Cursor providers
  Storage/        KeychainStore, SQLiteStore, UsageSnapshotCache
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
- **Cursor** (`Sources/Providers/Cursor/`): login read from Cursor's own
  `state.vscdb` (`SQLiteCLIStore`, read-only `sqlite3`) with the
  `cursor-access-token` Keychain items as fallback; usage from
  `GetCurrentPeriodUsage`, mapped into one `.billingPeriod` window. Neither
  source is ever written back.
- **Settings/Notifications**: persisted `AppSettings` wired live;
  UNUserNotificationCenter thresholds with per-window cooldown.

## Distribution

`scripts/package-dmg.sh` builds the signed `.dmg`; `scripts/release.sh` tags,
publishes the GitHub Release, and updates the Homebrew cask. The cask source
of truth is `packaging/homebrew/mana.rb`; it is copied into the separate tap
repository (`TinyFrontier/homebrew-tap`, installed as `TinyFrontier/tap`)
because Homebrew requires taps to be named `homebrew-<name>`.

Builds are signed with an **Apple Development** identity and are **not
notarized** (needs a paid Developer Program membership), so Gatekeeper rejects
them as if downloaded. The cask works around that with a `postflight` that
strips `com.apple.quarantine`, disclosed in its `caveats`. Drop that block
once a Developer ID certificate exists.

Known TODOs: explicit monitor picker, deep multi-monitor/Spaces
handling, Developer ID certificate + notarization.
