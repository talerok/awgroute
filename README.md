# AwgRoute

Личный macOS-клиент для AmneziaWG с продвинутым роутингом (домены, GeoIP, rule-sets) поверх AWG-обфускации. Использует [`amnezia-box`](https://github.com/hoaxisr/amnezia-box) (форк sing-box) как backend.

См. [PLAN.md](PLAN.md) — общий план, [DECISIONS.md](DECISIONS.md) — принятые архитектурные решения, [PROGRESS.md](PROGRESS.md) — статус.

## Требования

- macOS 13+ (Apple Silicon — основная цель)
- Xcode 16+
- Go 1.23+ (для сборки backend) — `brew install go`
- `.conf`-файл AmneziaWG-сервера (получается из родного клиента AmneziaVPN или self-hosted)

## Сборка backend

```sh
backend/build.sh             # клонирует hoaxisr/amnezia-box (тег 1.12.12-awg) и собирает бинарник
FORCE=1 backend/build.sh     # переклонировать src
REF=main backend/build.sh    # другой git ref
```

Готовый бинарь: `backend/amnezia-box`.

## Smoke-тест backend (без GUI)

```sh
backend/amnezia-box check -c tests/configs/test.json     # парсинг + валидация конфига, без root
sudo backend/amnezia-box run   -c tests/configs/test.json # фактический запуск туннеля (нужен реальный сервер!)
```

При работающем туннеле:

```sh
curl -s http://127.0.0.1:9090/version    # Clash API
curl -s ifconfig.me                      # должен показать IP сервера
```

`tests/configs/test.json` содержит **placeholder-ключи** — настоящего туннеля он не поднимет. Замените `private_key`, `peers[].public_key`, `peers[].address`, `peers[].port` на свои перед запуском.

## Структура

```
backend/         сборка amnezia-box (Go)
shared/          общий Swift-код (AwgConfig — парсер .conf)
app/             SwiftUI GUI
resources/       JSON-шаблоны правил
tests/           тестовые .conf и JSON-конфиги (БЕЗ реальных ключей)
```

## Безопасность

- Реальные `.conf` файлы и приватные ключи **не коммитятся** (см. `.gitignore`).
- В GUI приватные ключи хранятся в Keychain.
