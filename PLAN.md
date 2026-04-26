# План разработки: AmneziaWG клиент для macOS с продвинутым роутингом

## О проекте

Личный VPN-клиент для macOS на базе **amnezia-box** (форк sing-box с поддержкой AmneziaWG). Клиент даёт Clash-уровневый роутинг (домены, GeoIP, rule-sets) поверх AWG-обфускации — то, чего не умеет нативный AmneziaVPN.

Рабочее название: `AwgRoute` (можно изменить).

**Контекст использования:**
- Это приложение **для личного использования** на собственных машинах
- НЕ для App Store
- НЕ для широкого распространения
- Подпись и нотаризация не требуются

Это сильно упрощает архитектуру — см. раздел «Что упрощается».

## Принцип работы агента

Действуй автономно. Не задавай уточняющих вопросов по реализации — выбирай разумный default, документируй в `DECISIONS.md`, двигайся дальше. Эскалируй только если:
- Решение влияет на безопасность данных пользователя и нет очевидно безопасного варианта
- Блокер требует внешних ресурсов, которых нет
- Архитектура фундаментально не работает и нужен редизайн

В сомнениях — **делай**. Не пиши план и не жди одобрения. Реализуй, тестируй, документируй, переходи к следующему этапу.

## Ключевые факты

1. **amnezia-box уже умеет всё ядро.** Это форк sing-box с AmneziaWG endpoint. Не пиши свой VPN-движок, не реверсь WireGuard. Используй amnezia-box как backend через subprocess.

2. **Источник:** `https://github.com/hoaxisr/amnezia-box`. Бери последний релиз с тегом `awg2.0`.

3. **Пользователь приносит `.conf` файлы сам** из официального AmneziaVPN-клиента или self-hosted сервера. Мы НЕ реверсим control plane Amnezia, НЕ парсим `vpn://` ключи. Только готовые `.conf`.

4. **TUN требует root.** На macOS — через `sudo` запуск amnezia-box. Никакого Helper Tool для личного приложения не нужно.

5. **NetworkExtension НЕ используем.** amnezia-box работает в userspace со своим TUN — это работает напрямую, без Apple-фреймворков.

6. **Целевая платформа:** macOS 13+, под архитектуру разработчика (arm64 если M-series, x86_64 если Intel). Universal Binary не обязателен.

## Что упрощается из-за «личного» статуса

| Аспект | Полноценное приложение | Личное |
|---|---|---|
| Apple Developer аккаунт | $99/год обязательно | Не нужен |
| Code signing | Developer ID обязательно | Ad-hoc или без подписи |
| Notarization | Обязательна | Не нужна |
| Helper Tool + SMAppService + XPC | Нужен (привилегии) | Не нужен — `sudo` |
| Hardened Runtime + entitlements | Обязательно | Не нужно |
| Sparkle для автообновлений | Желательно | Не нужно |
| DMG-сборка | Желательно | Не нужно |
| Universal Binary | Желательно | Не нужно |
| Полная обработка edge cases | Обязательно | По мере необходимости |

**Что это означает на практике:** можно сосредоточиться на функциональности, а не на инфраструктуре дистрибуции. Билд → запустил у себя → работает.

## Архитектура

```
GUI App (SwiftUI)
   │
   │  запускает через AppleScript "do shell script with administrator privileges"
   │  или через заранее настроенный sudoers
   ▼
amnezia-box (subprocess, root)
   ├── TUN interface (utunN)
   ├── AWG endpoint (обфускация)
   ├── Clash rule engine (правила роутинга)
   └── Clash API на 127.0.0.1:9090
```

GUI читает `.conf` профили, генерирует JSON-конфиг для amnezia-box, запускает его как subprocess с правами root, общается с работающим процессом через Clash API для статуса/метрик/переключений.

## Структура репозитория

```
/
├── PLAN.md                      # этот файл
├── DECISIONS.md                 # лог принятых архитектурных решений
├── PROGRESS.md                  # текущий статус по этапам
├── README.md                    # для человека: как собрать и запустить
├── app/                         # GUI приложение (SwiftUI)
│   ├── AwgRoute.xcodeproj
│   └── Sources/
├── shared/                      # переиспользуемый Swift код
│   └── Sources/
│       └── AwgConfig/           # парсер .conf, генератор JSON
├── backend/
│   ├── build.sh                 # скрипт сборки amnezia-box из исходников
│   └── amnezia-box              # бинарник (gitignore)
├── resources/
│   ├── rule-presets/            # JSON-пресеты правил
│   └── default-config.json      # шаблон конфига amnezia-box
├── scripts/
│   └── run-dev.sh               # запуск dev-сборки с sudo
└── tests/
    ├── conf-samples/            # тестовые .conf (БЕЗ реальных ключей!)
    └── configs/                 # тестовые JSON для amnezia-box
```

## Этапы

Выполняй последовательно. После каждого этапа: обнови `PROGRESS.md`, закоммить с понятным сообщением, переходи дальше.

### Этап 0: Backend готов

**Цель:** amnezia-box собирается и работает с тестовым конфигом.

Задачи:

- [ ] Создать `backend/build.sh`: клонирует `hoaxisr/amnezia-box` в temp-директорию, собирает с правильными тегами, кладёт бинарник в `backend/amnezia-box`. Команда сборки:
  ```
  go build -tags "with_gvisor,with_quic,with_dhcp,with_wireguard,with_utls,with_acme,with_clash_api,with_awg" \
    -o amnezia-box ./cmd/sing-box
  ```
- [ ] Изучить исходники amnezia-box, найти точное определение AWG endpoint опций. Искать файлы вроде `option/wireguard.go`, `option/endpoint.go`, или похожее. Точные имена JSON-полей и их типы зафиксировать в `DECISIONS.md`.
- [ ] Создать тестовый `.conf` в `tests/conf-samples/example.conf` (с placeholder-ключами или реальный — на твоё усмотрение, но не коммить реальные)
- [ ] Создать вручную `tests/configs/test.json` — рабочий JSON-конфиг amnezia-box
- [ ] Проверить запуск: `sudo backend/amnezia-box run -c tests/configs/test.json`
- [ ] Проверить, что туннель работает: `curl ifconfig.me` показывает IP сервера
- [ ] Проверить Clash API: `curl http://127.0.0.1:9090/version`

**Done when:** amnezia-box стабильно держит туннель, Clash API отвечает, формат AWG endpoint полностью задокументирован в `DECISIONS.md`.

### Этап 1: Парсер `.conf` и генератор JSON

**Цель:** Swift Package, который читает `.conf` → структура → JSON для amnezia-box.

Задачи:

- [ ] Swift Package `AwgConfig` в `shared/Sources/AwgConfig/`
- [ ] Структура `AwgConfig` со всеми полями `[Interface]` и `[Peer]`:
  - Interface: `address`, `privateKey`, `dns`, `mtu`, `listenPort`, `jc`, `jmin`, `jmax`, `s1-s4`, `h1-h4`, `i1-i5`, `j1-j3`, `itime`
  - Peer: `publicKey`, `presharedKey`, `endpoint` (host + port), `allowedIPs`, `persistentKeepalive`
- [ ] Парсер INI-формата (без внешних зависимостей)
- [ ] Генератор JSON для секции `endpoints` amnezia-box (имена полей строго из `DECISIONS.md`)
- [ ] Генератор полного JSON-конфига: TUN inbound + AWG endpoint + базовая `route` секция
- [ ] Unit-тесты на 5+ примерах (с обфускацией/без, с PSK/без, минимальные/полные)

**Critical:** Параметры `I1-I5` — это строки со спецсинтаксисом (`<b 0xff><c><t><r 10>`). НЕ парси их и НЕ валидируй. Копируй as-is из `.conf` в JSON.

**Done when:** все тесты зелёные, сгенерированный JSON принимается amnezia-box без ошибок при ручном запуске с любым из тестовых `.conf`.

### Этап 2: Запуск backend из GUI

**Цель:** GUI может запускать и останавливать amnezia-box с правами root.

Задачи:

- [ ] Создать Xcode-проект SwiftUI app в `app/`
- [ ] Класс `BackendController`:
  - `start(configPath: String) async throws`
  - `stop() async`
  - `status() -> Status` (running / stopped / error)
  - `logs() -> AsyncStream<String>` (стрим stdout/stderr)
- [ ] Запуск amnezia-box через `Process` с `sudo`. Самый простой способ для личного приложения:
  - **Вариант A:** AppleScript через `NSAppleScript` с `do shell script ... with administrator privileges` — macOS показывает диалог пароля один раз за сессию
  - **Вариант B:** Настроить sudoers заранее: `<username> ALL=(ALL) NOPASSWD: /path/to/amnezia-box` — без пароля, но требует разовой ручной настройки
  - Выбери Вариант A для начала, документируй в `DECISIONS.md`
- [ ] Логи backend пишутся в `~/Library/Logs/AwgRoute/amnezia-box.log` с базовой ротацией (раз в день или по размеру)
- [ ] Корректная остановка: SIGTERM, потом SIGKILL через 5 сек
- [ ] Cleanup при выходе GUI: убедиться, что amnezia-box не остаётся висеть

**Done when:** stub-приложение с двумя кнопками Start/Stop стабильно поднимает и опускает туннель, переживает перезапуск GUI без зависших процессов.

### Этап 3: GUI — управление профилями

**Цель:** импорт, хранение, переключение `.conf` профилей.

Задачи:

- [ ] Главное окно: список профилей слева, детали справа, большая кнопка Connect/Disconnect снизу
- [ ] Импорт `.conf`:
  - Через NSOpenPanel (кнопка «Import»)
  - Drag-and-drop файлов в окно
  - Парсинг через `AwgConfig`, валидация
- [ ] Метаданные профиля: имя (по умолчанию из имени файла), заметки (опционально), время создания
- [ ] Хранение профилей: `~/Library/Application Support/AwgRoute/profiles/<uuid>.json`
- [ ] Приватные ключи — в Keychain (`kSecClassGenericPassword`, accessible after first unlock). В JSON-файле профиля только reference на Keychain item.
- [ ] Активный профиль помечен галочкой
- [ ] Переключение профиля: если туннель активен — stop → переписать конфиг → start, с прогресс-индикатором
- [ ] Удаление профиля + автоматический cleanup из Keychain
- [ ] Просмотр полей профиля (read-only, ключи замаскированы)

**Done when:** импорт 3+ разных профилей работает, переключение между ними одним кликом, ключи лежат в Keychain (проверь через Keychain Access).

### Этап 4: GUI — JSON-редактор правил

**Цель:** пользователь сам пишет JSON для секции `route` (и опционально `dns`/`rule_set`). Никакого визуального редактора — текстовый редактор с подсветкой, валидацией и шаблонами.

**Решение:** scope правил — **глобальный** (общий для всех профилей). Документируй в `DECISIONS.md`. Правила меняются редко, профили часто — отдельное хранение удобнее.

Задачи:

- [ ] Вкладка/окно «Rules» с большим текстовым редактором JSON
- [ ] Подсветка синтаксиса JSON. Варианты:
  - `CodeEditor` SwiftUI-компонент (есть готовые на GitHub, например `CodeEditor` от mikemikina)
  - WebView с Monaco/CodeMirror (мощно, но тяжело)
  - Базовый `TextEditor` + ручная подсветка через AttributedString (минимум усилий)
  - Default: начни с `TextEditor`, апгрейдь если будет мешать
- [ ] Валидация в реальном времени:
  - JSON parsability (стандартный `JSONSerialization`)
  - Опционально — schema-валидация структуры sing-box route (можно пропустить, amnezia-box сам отвергнет невалидное)
  - Индикатор статуса: ✅ valid JSON / ❌ syntax error на строке N
- [ ] Хранение: `~/Library/Application Support/AwgRoute/rules.json`
- [ ] Кнопки в редакторе:
  - **Apply** — записывает rules.json, перегенерирует конфиг amnezia-box, перезапускает backend
  - **Revert** — откатить несохранённые изменения
  - **Format** — отформатировать JSON (pretty-print)
  - **Insert template** — выпадающее меню с готовыми шаблонами (см. ниже)
- [ ] Шаблоны (вставляются в редактор как отправная точка, пользователь правит):
  - **Empty** — минимальный валидный JSON: только sniff + hijack-dns + final
  - **RU routing** — российские сайты direct, остальное через VPN
  - **Ad blocking** — добавление reject-правила для рекламы
  - **Full Clash-style** — комплексный пример с rule_set, DNS, GeoIP
  - Шаблоны хранить в `resources/rule-presets/*.json`, грузить из bundle
- [ ] Генератор финального конфига amnezia-box объединяет:
  - Активный AWG-профиль → секция `endpoints`
  - rules.json от пользователя → секция `route` (и опционально `dns`, если пользователь её туда положил)
  - Стандартные `log`, `inbounds` (TUN) — из захардкоженного шаблона
  - Записывает в `~/Library/Application Support/AwgRoute/active-config.json`
- [ ] При Apply: если backend запущен — graceful restart с новым конфигом

**Что пользователь пишет в rules.json:**

Один из двух форматов на выбор (определись и зафиксируй в `DECISIONS.md`):

**Вариант A — только секция route:**
```json
{
  "rules": [
    { "action": "sniff" },
    { "protocol": "dns", "action": "hijack-dns" },
    { "domain_suffix": [".ru"], "outbound": "direct" }
  ],
  "rule_set": [...],
  "final": "awg-out"
}
```
Генератор оборачивает это в полный конфиг.

**Вариант B — полные секции `route` и опционально `dns`:**
```json
{
  "route": { ... },
  "dns": { ... }
}
```
Гибче, но требует от пользователя понимать структуру глубже.

**Рекомендация: Вариант A.** Меньше boilerplate, проще шаблоны.

**Critical:**
- В шаблонах `Empty` и всех остальных ВСЕГДА присутствуют `{ "action": "sniff" }` и `{ "protocol": "dns", "action": "hijack-dns" }` в начале правил. Без них доменные правила не работают.
- `final` должен ссылаться на тег AWG endpoint активного профиля. Генератор подставляет правильный тег автоматически — пользователь в JSON может писать `"final": "vpn"` (зарезервированное имя), а генератор заменяет на актуальный тег.
- Если пользователь пишет невалидный JSON и жмёт Apply — НЕ перезапускай backend. Покажи ошибку, оставь работать со старым конфигом.

**Done when:**
- Пользователь открывает Rules, вставляет шаблон «RU routing», нажимает Apply
- Backend перезапускается, российские сайты идут напрямую, остальное через VPN
- Сломанный JSON не ломает работающий туннель

### Этап 5: Мониторинг

**Цель:** показать пользователю, что происходит.

Задачи:

- [ ] Status bar item (значок в menu bar) с цветовой индикацией:
  - Серый — отключено
  - Жёлтый — подключается
  - Зелёный — подключено
  - Красный — ошибка
- [ ] В главном окне:
  - Текущий внешний IP (через VPN или реальный)
  - Аптайм соединения
  - Скорость RX/TX (через Clash API `/traffic`, websocket)
- [ ] Вкладка «Logs» — читает `amnezia-box.log` с автообновлением (tail-style)
- [ ] Вкладка «Connections» — последние N соединений (домен, outbound, время) через Clash API `/connections`. Можно сделать просто или вообще опустить на старте.

**Done when:** видно, какие домены идут через VPN, а какие напрямую, в реальном времени.

### Этап 6: Полировка (по необходимости)

Делать только то, что реально нужно для личного использования. Не делать всё подряд.

Кандидаты:

- [ ] **Sleep/wake** — переподключение после сна. Подписка на `NSWorkspace.didWakeNotification`.
- [ ] **Смена сети** — переподключение при переходе Wi-Fi ↔ Ethernet. `NWPathMonitor`.
- [ ] **Автозапуск** — Login Item через `SMAppService.loginItem`.
- [ ] **Auto-connect on launch** — опция в настройках.
- [ ] **Quick connect** — горячая клавиша для toggle.
- [ ] **Update from .conf** — кнопка в профиле «обновить из исходного файла» для актуализации параметров обфускации.

Не делай это всё сразу. Начни без — добавляй то, что реально мешает в повседневном использовании.

## Что НЕ делать

- ❌ Не реверсить control plane Amnezia, формат `vpn://` ключей, ротацию параметров
- ❌ Не использовать NetworkExtension framework
- ❌ Не писать свой WireGuard/AmneziaWG код
- ❌ Не дублировать rule engine — всё через JSON-конфиг amnezia-box
- ❌ Не делать Helper Tool / XPC / SMAppService — это нужно для distribution, не для себя
- ❌ Не подписывать и не нотаризовать — личное использование
- ❌ Не делать Universal Binary — собирай под свою архитектуру
- ❌ Не делать Sparkle, DMG, инсталляторы — `xcodebuild` + копирование в `/Applications/`

## Критические места, где легко ошибиться

1. **Формат AWG-endpoint в JSON.** Имена полей специфичны для amnezia-box и могут отличаться от стандартного WireGuard outbound в sing-box. Всегда проверяй по исходникам `hoaxisr/amnezia-box`. Не выдумывай поля.

2. **Параметры `I1-I5`.** Это специальный синтаксис обфускации. Копируй as-is, не парси.

3. **TUN на macOS требует root.** AppleScript-prompt — единственный лёгкий путь без Helper Tool.

4. **Keychain.** Если хранить ключи в JSON-файле — они скомпрометированы при утечке backup'а. Используй Keychain с правильным access control.

5. **`sniff` action обязателен** в начале route rules. Без него домены из TLS SNI не извлекаются, доменные правила не работают.

6. **`hijack-dns` обязателен.** Без него DNS уходит мимо туннеля, FakeIP не работает.

7. **Не коммить реальные `.conf` файлы.** Тестовые в `tests/conf-samples/` — только с placeholder ключами (или сделай их gitignore).

## Минимальный MVP

Если хочется «работает за день»:

1. CLI вместо GUI: Swift command-line tool, читает `.conf` из аргумента, генерирует JSON, запускает amnezia-box через `sudo`
2. Один профиль за запуск
3. Правила в текстовом файле (не GUI)
4. Без status bar, без логов в окне

Это даёт работающую штуку за 1-2 дня для проверки концепции. Потом обрастает GUI.

## Ресурсы

- amnezia-box (форк с AWG 2.0 фиксами): https://github.com/hoaxisr/amnezia-box
- Оригинальный форк от Amnezia: https://github.com/amnezia-vpn/amnezia-box
- Документация sing-box (применима к большинству фич): https://sing-box.sagernet.org/
- Готовые rule-sets для русского контекста: https://github.com/runetfreedom/russia-v2ray-rules-dat
- Базовые GeoIP/GeoSite: https://github.com/SagerNet/sing-geoip, https://github.com/SagerNet/sing-geosite
- Документация AmneziaWG протокола: https://docs.amnezia.org/documentation/amnezia-wg/

## Финальная проверка

Готовый клиент должен:

1. Импортировать `.conf` от Amnezia Premium или self-hosted в один клик
2. Хранить несколько профилей и переключаться между ними одним кликом
3. Давать редактировать правила роутинга в JSON-редакторе с шаблонами и валидацией
4. Иметь набор готовых JSON-шаблонов для типовых кейсов (RU-роутинг, реклама, торренты)
5. Показывать статус в menu bar
6. Запускаться, держать туннель, корректно останавливаться
7. Поддерживать обновление параметров обфускации через переимпорт `.conf`

Всё. Никаких подписей, нотаризации, App Store, поддержки тысяч пользователей.
