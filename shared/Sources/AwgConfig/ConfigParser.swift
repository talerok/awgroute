import Foundation
import AwgDomain

public enum AwgConfigParser {

    public static func parse(_ text: String) throws -> AwgConfig {
        let sections = try INIParser.parse(text)

        var interfaceSection: INIParser.Section? = nil
        var peerSections: [INIParser.Section] = []
        for s in sections {
            switch s.name.lowercased() {
            case "interface": interfaceSection = s
            case "peer":      peerSections.append(s)
            default:          continue   // неизвестные секции тихо игнорируем
            }
        }

        guard let ifaceSec = interfaceSection else {
            throw AwgConfigError.missingSection("Interface")
        }
        if peerSections.isEmpty {
            throw AwgConfigError.missingSection("Peer")
        }

        let (iface, ifaceWarnings) = try buildInterface(from: ifaceSec)
        var warnings = ifaceWarnings
        var peers: [AwgConfig.Peer] = []
        for sec in peerSections {
            let (peer, peerWarnings) = try buildPeer(from: sec)
            peers.append(peer)
            warnings.append(contentsOf: peerWarnings)
        }

        return AwgConfig(interface: iface, peers: peers, warnings: warnings)
    }

    // MARK: - Interface

    /// Ключи, которых нет в схеме amnezia-box (`option/awg.go`). Парсим, но не
    /// переносим в JSON — иначе backend упадёт на unknown field.
    /// J1-J3/Itime встречаются в старых конфигах Amnezia-клиента.
    private static let unsupportedInterfaceKeys: Set<String> = [
        "j1", "j2", "j3", "itime"
    ]

    private static func buildInterface(from section: INIParser.Section) throws -> (AwgConfig.Interface, [String]) {
        var address: [String] = []
        var privateKey: String? = nil
        var dns: [String] = []
        var mtu: UInt32? = nil
        var listenPort: UInt16? = nil
        var jc: Int?, jmin: Int?, jmax: Int?
        var s1: Int?, s2: Int?, s3: Int?, s4: Int?
        var h1: String?, h2: String?, h3: String?, h4: String?
        var i1: String?, i2: String?, i3: String?, i4: String?, i5: String?
        var headerProtectionKey: String?
        var contentPaddingAddition: AwgRange?, rekeyAfterTime: AwgRange?, rekeyTimeout: AwgRange?
        var rejectAfterTime: AwgRange?, keepaliveTimeout: AwgRange?, maxHandshakeAttempts: AwgRange?
        var warnings: [String] = []

        func range(_ v: String, _ key: String) throws -> AwgRange {
            guard let r = AwgRange(v) else { throw AwgConfigError.invalidNumber(key: key, value: v) }
            return r
        }

        // Диапазон `min-max` (AWG 1.5) схлопывается в середину: backend принимает
        // одно число. Каждое схлопывание пишем в warnings.
        func int(_ v: String, _ key: String) throws -> Int {
            try parseInt(v, key: key, warnings: &warnings)
        }

        for entry in section.entries {
            let k = entry.key.lowercased()
            let v = entry.value
            switch k {
            case "address":
                address.append(contentsOf: splitList(v))
            case "privatekey":
                privateKey = v
            case "dns":
                dns.append(contentsOf: splitList(v))
            case "mtu":
                mtu = try parseUInt32(v, key: "MTU", warnings: &warnings)
            case "listenport":
                listenPort = try parseUInt16(v, key: "ListenPort", warnings: &warnings)
            case "jc":   jc   = try int(v, "Jc")
            case "jmin": jmin = try int(v, "Jmin")
            case "jmax": jmax = try int(v, "Jmax")
            case "s1":   s1   = try int(v, "S1")
            case "s2":   s2   = try int(v, "S2")
            case "s3":   s3   = try int(v, "S3")
            case "s4":   s4   = try int(v, "S4")
            case "h1":   h1   = v.isEmpty ? nil : v
            case "h2":   h2   = v.isEmpty ? nil : v
            case "h3":   h3   = v.isEmpty ? nil : v
            case "h4":   h4   = v.isEmpty ? nil : v
            // I1-I5 — спецсинтаксис обфускации, копируем as-is, но теги проверяем:
            // неизвестный тег backend отвергает на старте (`IPC error -22: failed to
            // parse I1: unknown tag <c>`), и без проверки это всплывало бы FATAL'ом
            // в логе через минуту после Connect вместо понятного сообщения.
            case "i1":   i1   = v.isEmpty ? nil : v; warnings += unknownTagWarnings(v, key: entry.key)
            case "i2":   i2   = v.isEmpty ? nil : v; warnings += unknownTagWarnings(v, key: entry.key)
            case "i3":   i3   = v.isEmpty ? nil : v; warnings += unknownTagWarnings(v, key: entry.key)
            case "i4":   i4   = v.isEmpty ? nil : v; warnings += unknownTagWarnings(v, key: entry.key)
            case "i5":   i5   = v.isEmpty ? nil : v; warnings += unknownTagWarnings(v, key: entry.key)
            // ── AmneziaWG 3.x ──
            // Диапазоны едут в backend дословно: устройство сэмплирует значение
            // внутри интервала на каждом взводе таймера, в этом весь смысл.
            case "headerprotectionkey":
                headerProtectionKey = v.isEmpty ? nil : v
            case "contentpaddingaddition":
                contentPaddingAddition = try range(v, entry.key)
            case "rekeyaftertime":
                rekeyAfterTime = try range(v, entry.key)
            case "rekeytimeout":
                rekeyTimeout = try range(v, entry.key)
            case "rejectaftertime":
                rejectAfterTime = try range(v, entry.key)
            case "keepalivetimeout":
                keepaliveTimeout = try range(v, entry.key)
            case "maxhandshakeattempts":
                maxHandshakeAttempts = try range(v, entry.key)
            case _ where unsupportedInterfaceKeys.contains(k):
                warnings.append("Ignored unsupported AWG parameter \(entry.key)=\(v) — not defined in amnezia-box AwgEndpointOptions")
            default:
                warnings.append("Unknown [Interface] key: \(entry.key)")
            }
        }

        guard !address.isEmpty else {
            throw AwgConfigError.missingRequiredKey(section: "Interface", key: "Address")
        }
        guard let pk = privateKey, !pk.isEmpty else {
            throw AwgConfigError.missingRequiredKey(section: "Interface", key: "PrivateKey")
        }

        let iface = AwgConfig.Interface(
            address: address, privateKey: pk, dns: dns, mtu: mtu, listenPort: listenPort,
            jc: jc, jmin: jmin, jmax: jmax,
            s1: s1, s2: s2, s3: s3, s4: s4,
            h1: h1, h2: h2, h3: h3, h4: h4,
            i1: i1, i2: i2, i3: i3, i4: i4, i5: i5,
            headerProtectionKey: headerProtectionKey,
            contentPaddingAddition: contentPaddingAddition,
            rekeyAfterTime: rekeyAfterTime,
            rekeyTimeout: rekeyTimeout,
            rejectAfterTime: rejectAfterTime,
            keepaliveTimeout: keepaliveTimeout,
            maxHandshakeAttempts: maxHandshakeAttempts
        )

        // Backend откажется стартовать с `s<N> must be at least 12 when
        // header_protection_key is set`. Ловим здесь, чтобы это было видно
        // при импорте, а не FATAL'ом в логе через минуту.
        if headerProtectionKey != nil {
            let tooSmall = [("S1", s1), ("S2", s2), ("S3", s3), ("S4", s4)]
                .filter { $0.1 != nil && $0.1! < 12 }
                .map { "\($0.0)=\($0.1!)" }
            if !tooSmall.isEmpty {
                warnings.append(
                    "HeaderProtectionKey требует S1-S4 не меньше 12, а здесь \(tooSmall.joined(separator: ", "))"
                    + " — backend откажется стартовать."
                )
            }
        }
        return (iface, warnings)
    }

    // MARK: - Peer

    private static func buildPeer(from section: INIParser.Section) throws -> (AwgConfig.Peer, [String]) {
        var publicKey: String? = nil
        var presharedKey: String? = nil
        var endpoint: (String, UInt16)? = nil
        var allowedIPs: [String] = []
        var keepalive: AwgRange? = nil
        var warnings: [String] = []

        for entry in section.entries {
            let k = entry.key.lowercased()
            let v = entry.value
            switch k {
            case "publickey":      publicKey = v
            case "presharedkey":   presharedKey = v.isEmpty ? nil : v
            case "endpoint":       endpoint = try parseEndpoint(v)
            case "allowedips":     allowedIPs.append(contentsOf: splitList(v))
            case "persistentkeepalive":
                // AWG 3.x: диапазон допустим и передаётся backend'у как есть.
                guard let r = AwgRange(v) else {
                    throw AwgConfigError.invalidNumber(key: "PersistentKeepalive", value: v)
                }
                keepalive = r
            default:
                warnings.append("Unknown [Peer] key: \(entry.key)")
            }
        }

        guard let pk = publicKey, !pk.isEmpty else {
            throw AwgConfigError.missingRequiredKey(section: "Peer", key: "PublicKey")
        }
        guard let ep = endpoint else {
            throw AwgConfigError.missingRequiredKey(section: "Peer", key: "Endpoint")
        }
        guard !allowedIPs.isEmpty else {
            throw AwgConfigError.missingRequiredKey(section: "Peer", key: "AllowedIPs")
        }

        let peer = AwgConfig.Peer(
            publicKey: pk,
            presharedKey: presharedKey,
            endpointHost: ep.0,
            endpointPort: ep.1,
            allowedIPs: allowedIPs,
            persistentKeepalive: keepalive
        )
        return (peer, warnings)
    }

    // MARK: - helpers

    /// Теги генераторов для I1-I5, которые понимает amneziawg-go v3 (`device/obf.go`).
    /// AWG 1.5 знал ещё `<c>` (счётчик пакетов) — в v3 его нет.
    static let supportedObfuscationTags: Set<String> = ["b", "t", "r", "rc", "rd", "d", "ds", "dz"]

    /// Разбирает `<tag ...>`-цепочку и возвращает warning на каждый неизвестный тег.
    static func unknownTagWarnings(_ value: String, key: String) -> [String] {
        var result: [String] = []
        var rest = Substring(value)
        while let open = rest.firstIndex(of: "<") {
            guard let close = rest[open...].firstIndex(of: ">") else { break }
            let tag = rest[rest.index(after: open)..<close]
            if let name = tag.split(separator: " ").first.map(String.init),
               !supportedObfuscationTags.contains(name) {
                result.append(
                    "\(key): неизвестный тег <\(name)> — backend его не примет "
                    + "(поддерживаются: \(supportedObfuscationTags.sorted().joined(separator: ", ")))"
                )
            }
            rest = rest[rest.index(after: close)...]
        }
        return result
    }

    private static func splitList(_ value: String) -> [String] {
        value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Нормализует значение числового ключа.
    ///
    /// Схлопывает диапазон в середину — для полей, которые backend принимает
    /// СКАЛЯРОМ (`jc`, `jmin`, `jmax`, `s1`-`s4`, `mtu`, `listen_port`).
    ///
    /// Range-типизированные параметры AWG 3.x (`PersistentKeepalive`, тайминги)
    /// сюда НЕ попадают: они уходят в backend дословно, потому что рандомизация
    /// внутри интервала — и есть их смысл.
    ///
    /// Середина, а не случайное значение: иначе один и тот же `.conf` давал бы
    /// разные профили и ломал сравнение `AwgConfig` на равенство.
    ///
    /// Возвращает nil, если значение не является диапазоном.
    private static func collapseRange(_ s: String, key: String, warnings: inout [String]) -> String? {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2,
              let lo = Int(parts[0]), let hi = Int(parts[1]),
              lo >= 0, hi >= lo else { return nil }
        let mid = lo + (hi - lo) / 2
        warnings.append(
            "\(key)=\(s) — диапазон, но backend принимает \(key) скаляром; взято \(mid)"
        )
        return String(mid)
    }

    private static func normalizedNumber(_ s: String, key: String, warnings: inout [String]) -> String {
        collapseRange(s, key: key, warnings: &warnings) ?? s
    }

    private static func parseInt(_ s: String, key: String, warnings: inout [String]) throws -> Int {
        let v = normalizedNumber(s, key: key, warnings: &warnings)
        guard let n = Int(v) else { throw AwgConfigError.invalidNumber(key: key, value: s) }
        return n
    }
    private static func parseUInt16(_ s: String, key: String, warnings: inout [String]) throws -> UInt16 {
        let v = normalizedNumber(s, key: key, warnings: &warnings)
        guard let n = UInt16(v) else { throw AwgConfigError.invalidNumber(key: key, value: s) }
        return n
    }
    private static func parseUInt32(_ s: String, key: String, warnings: inout [String]) throws -> UInt32 {
        let v = normalizedNumber(s, key: key, warnings: &warnings)
        guard let n = UInt32(v) else { throw AwgConfigError.invalidNumber(key: key, value: s) }
        return n
    }

    /// Парсит `host:port`. host может быть IPv4, IPv6 в `[...]` или domain.
    static func parseEndpoint(_ raw: String) throws -> (String, UInt16) {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("[") {
            // [::1]:51820
            guard let close = s.firstIndex(of: "]") else { throw AwgConfigError.invalidEndpoint(raw) }
            let host = String(s[s.index(after: s.startIndex)..<close])
            let after = s.index(after: close)
            guard after < s.endIndex, s[after] == ":" else { throw AwgConfigError.invalidEndpoint(raw) }
            let portStr = String(s[s.index(after: after)...])
            guard let port = UInt16(portStr) else { throw AwgConfigError.invalidPort(portStr) }
            return (host, port)
        } else {
            guard let colon = s.lastIndex(of: ":") else { throw AwgConfigError.invalidEndpoint(raw) }
            let host = String(s[..<colon])
            let portStr = String(s[s.index(after: colon)...])
            guard !host.isEmpty else { throw AwgConfigError.invalidEndpoint(raw) }
            guard let port = UInt16(portStr) else { throw AwgConfigError.invalidPort(portStr) }
            return (host, port)
        }
    }
}
