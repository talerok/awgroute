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

## Этап 1 — AwgConfig
не начато

## Этап 2 — BackendController
не начато

## Этап 3 — GUI: профили
не начато

## Этап 4 — GUI: редактор правил
не начато

## Этап 5 — мониторинг
не начато
