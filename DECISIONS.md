# DECISIONS

Лог принятых архитектурных решений. Каждая запись: дата, контекст, решение, альтернативы.

---

## 2026-04-26 — Go installed via Homebrew

**Контекст:** для сборки amnezia-box нужен Go ≥ 1.21.

**Решение:** `brew install go` → go1.26.2 darwin/arm64. Скрипт сборки ищет `go` в `PATH`, fallback на `/opt/homebrew/bin/go`.

---

## 2026-04-26 — Целевая архитектура: arm64

**Контекст:** машина разработчика — Apple Silicon. Universal Binary не делаем (PLAN.md, «Что НЕ делать»).

**Решение:** все сборки под darwin/arm64. Если понадобится Intel — пересобрать с `GOARCH=amd64`.

---

## 2026-04-26 — Backend: subprocess с sudo

**Контекст:** TUN на macOS требует root. Helper Tool / SMAppService — overkill для личного приложения.

**Решение:** GUI запускает `backend/amnezia-box` через `Process` с эскалацией через `do shell script ... with administrator privileges` (NSAppleScript). Альтернатива через NOPASSWD sudoers — оставлена как опция для пользователя.

---

## 2026-04-26 — Backend ref: тег `1.12.12-awg` (а не `awg2.0`)

**Контекст:** PLAN.md упоминает тег `awg2.0`, которого в `hoaxisr/amnezia-box` нет. Доступны ветки `main` (sync с upstream stable-next), `alpha` (dev-next) и AWG-помеченные теги `1.12.12-awg`, `1.12.12-awg-notglobal`.

**Решение:** дефолтный ref — `1.12.12-awg`. Это последняя стабильная sing-box серия (1.12.x) с явной AWG-меткой. README репозитория подтверждает поддержку «AWG 2.0 features: H1-H4 ranges, S3/S4 padding, I1-I5 obfuscation chains».

**Альтернативы:** ветка `main` — получаем обновления, но теряем воспроизводимость. Тег `1.12.12-awg-notglobal` — судя по имени, без glob-маршрутизации, нам не нужен.

**Override:** `REF=main backend/build.sh`.

---

## 2026-04-26 — Спецификация AWG endpoint в JSON-конфиге amnezia-box

**Источник:** `backend/src/option/awg.go`, `backend/src/protocol/awg/endpoint.go` (тег `1.12.12-awg`).

**Регистрация типа:** `constant.TypeAwg = "awg"` → используется в секции `endpoints[].type`.

**Полная схема endpoint:**

```jsonc
{
  "type": "awg",                       // обязательно
  "tag": "vpn",                        // строка-идентификатор для route.final / outbound

  // ── ключевое ──
  "private_key": "<base64>",           // обязательно, base64 (Curve25519, 32 байта)
  "address": ["10.8.0.2/24"],          // обязательно, список Prefix (IPv4/IPv6 локальный адрес туннеля)
  "mtu": 1408,                         // optional, default 1408
  "listen_port": 0,                    // optional, обычно 0 (любой)

  // ── AWG-специфичное (всё optional, копируется как есть из .conf) ──
  "jc": 4,                             // junk packet count, int
  "jmin": 40, "jmax": 70,              // junk size range
  "s1": 0, "s2": 0, "s3": 0, "s4": 0,  // S1-S4 size paddings (S3/S4 — AWG 2.0)
  "h1": "", "h2": "", "h3": "", "h4": "", // H1-H4 magic header values (AWG 2.0 — диапазоны/строки)
  "i1": "", "i2": "", "i3": "", "i4": "", "i5": "", // I1-I5 obfuscation chains: спецсинтаксис типа "<b 0xff><c><t><r 10>" — копировать БЕЗ парсинга

  // ── netstack vs system tun ──
  "useIntegratedTun": false,           // false → пакеты идут через gvisor netstack и попадают в sing-box TUN inbound (наш режим)
                                       // true → AWG поднимает свой системный utun (нам не нужен — sing-box уже делает TUN inbound)

  // ── peers ──
  "peers": [{
    "address": "203.0.113.10",         // host (IP или domain) сервера
    "port": 51820,                      // uint16
    "public_key": "<base64>",           // обязательно
    "preshared_key": "<base64>",        // optional. ВНИМАНИЕ: имя поля `preshared_key`, без подчёркивания между pre/shared (в legacy WG было `pre_shared_key`)
    "allowed_ips": ["0.0.0.0/0", "::/0"], // обычно catch-all для full-tunnel
    "persistent_keepalive_interval": 25  // секунды, optional
  }],

  // ── DialerOptions (наследуется) ──
  // bind_interface, routing_mark, reuse_addr, connect_timeout, tcp_fast_open, ...
  // обычно не нужны, оставляем пусто
}
```

**Маппинг .conf → JSON:**

| .conf [Interface]     | JSON endpoint            | Примечание |
|-----------------------|--------------------------|------------|
| `Address`             | `address` (Listable)     | `10.0.0.2/32` → `["10.0.0.2/32"]` |
| `PrivateKey`          | `private_key`            | base64 как есть |
| `MTU`                 | `mtu`                    | uint32 |
| `ListenPort`          | `listen_port`            | обычно отсутствует |
| `Jc/Jmin/Jmax`        | `jc/jmin/jmax`           | int |
| `S1..S4`              | `s1..s4`                 | int |
| `H1..H4`              | `h1..h4`                 | string |
| `I1..I5`              | `i1..i5`                 | string, **копировать as-is** |
| `DNS`                 | (не в endpoint!)         | в `dns.servers[]` отдельной секции |
| `Jmax`, `S2`, `H1`... | передаются в IPC-конфиг amneziawg-go (см. `genIpcConfig` в `protocol/awg/endpoint.go`) |

| .conf [Peer]          | JSON peer                | Примечание |
|-----------------------|--------------------------|------------|
| `PublicKey`           | `public_key`             | base64 |
| `PresharedKey`        | `preshared_key`          | base64 (с одним подчёркиванием!) |
| `Endpoint`            | `address`+`port`         | `host:port` → разделить |
| `AllowedIPs`          | `allowed_ips`            | comma-list → array of CIDR |
| `PersistentKeepalive` | `persistent_keepalive_interval` | seconds |

**Параметры `J1-J3` и `Itime`:** в `option/awg.go` отсутствуют (`Jmin`, `Jmax`, `Jc` есть, остальные `J*` и `Itime` — нет). Если попадутся в `.conf` — игнорировать в генераторе и логировать предупреждение.

**Важно:** AWG endpoint работает в режиме `useIntegratedTun=false` — он создаёт netstack TUN внутри себя, sing-box перехватывает системный трафик через свой `tun` inbound, route направляет в AWG, AWG шифрует и пишет в физический сокет (через `bind` к dialer). Это объясняет, почему в нашей архитектуре нужен и `tun` inbound (для всего системного трафика), и `awg` endpoint (для шифрованной отправки наружу).

---

<!-- Добавлять новые записи сверху, под этой строкой -->
