# AwgRoute

Личный macOS-клиент для AmneziaWG с продвинутым роутингом (домены, GeoIP, rule-sets) поверх AWG-обфускации. Использует [`amnezia-box`](https://github.com/hoaxisr/amnezia-box) (форк sing-box) как backend.

## Требования

- macOS 13+ (Apple Silicon — основная цель)
- Xcode 16+
- Go 1.25+ (для сборки backend; требование `amneziawg-go/v3`) — `brew install go`
- `.conf`-файл AmneziaWG-сервера (получается из родного клиента AmneziaVPN или self-hosted)

Поддерживается AmneziaWG вплоть до 3.1: обфускация `Jc/Jmin/Jmax`, `S1-S4`, `H1-H4`, `I1-I5`,
header protection (`HeaderProtectionKey`) и диапазонные тайминги (`RekeyAfterTime = 100-120`,
`PersistentKeepalive = 25-35` и т.п.). Диапазоны передаются в backend дословно — устройство
само выбирает значение внутри интервала на каждом взводе таймера.

> `HeaderProtectionKey` требует `S1`-`S4` не меньше 12, иначе backend не стартует.
> Парсер предупреждает об этом при импорте профиля.

## Сборка

```sh
# 1. Backend (Go → amnezia-box)
backend/build.sh             # клонирует hoaxisr/amnezia-box (пин на коммит ветки awg-1.14.0) и собирает бинарник
FORCE=1 backend/build.sh     # переклонировать src
REF=main backend/build.sh    # другой git ref (тег, ветка или sha)

# 2. Privileged helper (Swift → awgroute-helper)
helper/build.sh              # собирает helper и кладёт бинарь в helper/awgroute-helper

# 3. Приложение (Xcode)
# Build phases вызывают helper/build.sh автоматически.
xcodebuild -project app/AwgRoute.xcodeproj -scheme AwgRoute -configuration Release \
           -derivedDataPath app/DerivedData CODE_SIGN_IDENTITY="-"
# Готовый .app: app/DerivedData/Build/Products/Release/AwgRoute.app
# Без -derivedDataPath Xcode кладёт результат в ~/Library/Developer/Xcode/DerivedData/AwgRoute-<hash>/
```

## Smoke-тест backend (без GUI)

```sh
backend/amnezia-box check -c tests/configs/test.json     # парсинг + валидация конфига, без root
sudo backend/amnezia-box run -c tests/configs/test.json  # фактический запуск туннеля (нужен реальный сервер!)
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
helper/          privileged helper-демон (Swift Package)
shared/          общий Swift-код (AwgConfig — парсер .conf и JSON-генератор)
app/             SwiftUI GUI (Xcode-проект)
resources/       JSON-пресеты правил роутинга
tests/           тестовые .conf и JSON-конфиги (БЕЗ реальных ключей)
```

## Архитектура

```
AwgRoute.app
├── amnezia-box           (backend, запускается как root-subprocess через helper)
├── awgroute-helper       (LaunchDaemon, управляет жизненным циклом amnezia-box)
└── SwiftUI GUI
    ├── ProfileStore      (профили + Keychain для приватных ключей)
    ├── RulesStore        (JSON-правила роутинга, редактируемые пользователем)
    ├── BackendController (статус, лог, start/stop)
    ├── ConnectionCoordinator (сборка конфига, запуск, переключение профилей)
    ├── NetworkWatcher    (silent reconnect при смене сети / wake-after-sleep)
    ├── Telemetry         (внешний IP, uptime, трафик через Clash API)
    └── MenuBarController (статус и быстрые действия в menu bar)
```

## Правила роутинга

Вкладка **Rules** редактирует `~/Library/Application Support/AwgRoute/rules.json`.

Файл — это содержимое секции `route` конфига amnezia-box (не весь конфиг):

```jsonc
{
  "rules": [
    { "domain_suffix": ["example.com"], "outbound": "direct" },
    { "rule_set": ["geoip-ru"], "outbound": "direct" }
  ],
  "rule_set": [
    {
      "type": "remote",
      "tag": "geoip-ru",
      "format": "binary",
      "url": "https://github.com/SagerNet/sing-geoip/raw/rule-set/geoip-ru.srs",
      "http_client": { "domain_resolver": { "server": "local" } },
      "update_interval": "7d"
    }
  ],
  "final": "vpn"
}
```

> **Важно:** поле `geoip` удалено в sing-box 1.12 — конфиг с ним не запустится
> (`geoip database is deprecated ... and removed`). Используйте `rule_set` с `.srs`,
> как в пресетах. У remote rule-set не указывайте `detour` в `http_client`:
> `direct` в 1.12+ — не outbound, а route-action, и detour на него отвергается.

Генератор автоматически добавляет `sniff` и `hijack-dns` в начало правил и выставляет `default_domain_resolver`.

> **Важно:** sing-box отвергает неизвестные поля — поле `comment` в правилах сломает конфиг.

## Безопасность

- Реальные `.conf`-файлы и приватные ключи **не коммитятся** (см. `.gitignore`).
- В приложении приватные ключи хранятся в Keychain; на диск пишется только sentinel `<keychain-ref>`.
- Активный конфиг с распакованным ключом кладётся в `~/Library/Caches/AwgRoute/` (исключён из Time Machine) и удаляется сразу после старта backend.
- Helper валидирует пути конфига (только `~/Library/Caches/AwgRoute/`, без `..`, без симлинков) и запускает строго `/Applications/AwgRoute.app/Contents/Resources/amnezia-box`.
