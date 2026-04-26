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

## Этап 2 — BackendController
не начато

## Этап 3 — GUI: профили
не начато

## Этап 4 — GUI: редактор правил
не начато

## Этап 5 — мониторинг
не начато
