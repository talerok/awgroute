# PROGRESS

Текущий статус по этапам из `PLAN.md`.

## Этап 0 — backend готов ✅

- [x] `backend/build.sh`
- [x] `amnezia-box` собран (тег `1.12.12-awg`, go1.26.2 darwin/arm64), `--help` и `version` работают
- [x] AWG endpoint опции задокументированы в `DECISIONS.md`
- [x] `tests/conf-samples/example.conf` (placeholder-ключи)
- [x] `tests/configs/test.json` — современный формат sing-box 1.12, проходит `amnezia-box check` без warnings
- [ ] **Ручная проверка:** `sudo amnezia-box run -c …` с реальным сервером — требует эскалации и реального endpoint, оставлено пользователю (см. README)
- [ ] **Ручная проверка:** Clash API `/version` — после ручного запуска

## Этап 1 — AwgConfig ✅

- [x] Swift Package `shared/` (target `AwgConfig`, executable `awgconfgen`)
- [x] Структуры `AwgConfig.Interface`, `AwgConfig.Peer` со всеми полями PLAN.md (минус `J1-J3/Itime` — их нет в `option/awg.go`, фиксируем через warnings)
- [x] INI-парсер без зависимостей, поддерживает `[Interface]`/`[Peer]`*N, IPv6 endpoint в `[...]`, лидирующие комментарии `#`/`;`
- [x] Генератор endpoint-JSON и полного конфига с merging пользовательских правил (sniff/hijack-dns подставляются автоматически, `final: "vpn"` → актуальный тег)
- [x] 16/16 unit-тестов зелёные
- [x] End-to-end: `awgconfgen` на всех 6 фикстурах → `amnezia-box check` exit 0

## Этап 2 — BackendController ✅ (real-server smoke-test остаётся ручным)

- [x] Xcode-проект `app/AwgRoute.xcodeproj` (генерится `xcodegen`-ом из `app/project.yml`)
- [x] SwiftUI scene, NSApplicationDelegateAdaptor для cleanup
- [x] `BackendController` с `start(configPath:)` / `stop()` / `status` / `logs` (AsyncStream)
- [x] Запуск через NSAppleScript «with administrator privileges» (Вариант A)
- [x] Сохранение PID в `/tmp/awgroute-amnezia-box.pid`, подцепление к живому процессу при перезапуске GUI
- [x] Логи в `~/Library/Logs/AwgRoute/amnezia-box.log`, ротация по размеру (>5 МБ → `.log.1`)
- [x] SIGTERM → 5 сек → SIGKILL
- [x] `applicationWillTerminate` → синхронный stop
- [x] Сборка `xcodebuild` зелёная, .app запускается без runtime-ошибок
- [ ] **Ручная проверка (требует UI и реального сервера):** Start/Stop с настоящим `.conf`, переживание перезапуска GUI

## Этап 3 — GUI: профили ✅

- [x] `Profile` Codable + `ProfileStore` (CRUD на `~/Library/Application Support/AwgRoute/profiles/<id>.json`)
- [x] `KeychainStore` (`kSecClassGenericPassword`, service=`dev.awgroute.profile-private-key`, `accessibleAfterFirstUnlock`); accounts `interface-pk-<id>` и `peer-psk-<id>-<i>`
- [x] Sentinel-маркер `<keychain-ref>` в JSON-метаданных вместо реальных секретов; материализация при connect
- [x] `ConnectionCoordinator`: профиль → `materializedConfig` → `AwgJSONGenerator.fullConfigJSON` → `Paths.activeConfig` → `backend.start`
- [x] `ContentView` переписан на `NavigationSplitView`: sidebar со списком профилей, detail с метаданными и кнопкой Connect/Disconnect
- [x] Импорт через `NSOpenPanel` и drag-and-drop
- [x] Удаление профиля + cleanup Keychain
- [x] Просмотр read-only с маскированными ключами
- [x] Активный профиль помечен ✓; UserDefaults persists `activeProfileID`
- [x] Переключение активного профиля через `coordinator.switchTo(profile:)` — graceful stop → start, если был запущен
- [x] AwgConfig теперь Codable, 16/16 тестов зелёные, .app собирается и запускается без runtime-ошибок
- [ ] **Ручная UI-проверка:** импорт реального .conf, Keychain Access показывает айтемы, переключение между 2+ профилями

## Этап 4 — GUI: редактор правил ✅

- [x] Глобальный scope правил, Вариант A — только секция `route` (см. `DECISIONS.md`)
- [x] `RulesStore`: load/save `~/Library/Application Support/AwgRoute/rules.json`, format, revert, real-time validation
- [x] `RulesEditorView`: TextEditor с monospaced шрифтом, Apply / Format / Revert / Insert template
- [x] Live-валидация: ✓ Valid JSON или ✗ ошибка с описанием
- [x] 4 пресета: Empty, RU routing, Ad blocking, Full Clash-style — лежат в `resources/rule-presets/`, бандлятся в .app
- [x] `ConnectionCoordinator` объединяет конфиг профиля и пользовательские правила (через `AwgJSONGenerator.fullConfigJSON(userRoute:)`)
- [x] Apply: сохранить → если backend запущен — graceful restart (`stop` → `connect`)
- [x] Сломанный JSON блокирует Apply (button disabled)
- [x] **End-to-end проверено:** все 4 пресета через `awgconfgen --rules` дают конфиг, который `amnezia-box check` принимает без ошибок
- [x] TabView: Tunnel | Rules
- [ ] **Ручная UI-проверка:** редактирование, Apply без перезапуска, проверка реальной маршрутизации

## Этап 5 — мониторинг
не начато
