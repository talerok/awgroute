import Foundation

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

        var (iface, ifaceWarnings) = try buildInterface(from: ifaceSec)
        let peers = try peerSections.map(buildPeer(from:))

        // Расхождение с .conf: dns обычно один list через запятую — нормализуем
        if iface.dns.count == 1, iface.dns[0].contains(",") {
            iface.dns = splitList(iface.dns[0])
        }

        return AwgConfig(interface: iface, peers: peers, warnings: ifaceWarnings)
    }

    // MARK: - Interface

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
        var warnings: [String] = []

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
                mtu = try parseUInt32(v, key: "MTU")
            case "listenport":
                listenPort = try parseUInt16(v, key: "ListenPort")
            case "jc":   jc   = try parseInt(v, key: "Jc")
            case "jmin": jmin = try parseInt(v, key: "Jmin")
            case "jmax": jmax = try parseInt(v, key: "Jmax")
            case "s1":   s1   = try parseInt(v, key: "S1")
            case "s2":   s2   = try parseInt(v, key: "S2")
            case "s3":   s3   = try parseInt(v, key: "S3")
            case "s4":   s4   = try parseInt(v, key: "S4")
            case "h1":   h1   = v.isEmpty ? nil : v
            case "h2":   h2   = v.isEmpty ? nil : v
            case "h3":   h3   = v.isEmpty ? nil : v
            case "h4":   h4   = v.isEmpty ? nil : v
            // I1-I5 — спецсинтаксис обфускации, копируем as-is
            case "i1":   i1   = v.isEmpty ? nil : v
            case "i2":   i2   = v.isEmpty ? nil : v
            case "i3":   i3   = v.isEmpty ? nil : v
            case "i4":   i4   = v.isEmpty ? nil : v
            case "i5":   i5   = v.isEmpty ? nil : v
            // Параметры, которые в .conf от Amnezia встречаются, но в amnezia-box нет
            case "j1", "j2", "j3", "itime":
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
            i1: i1, i2: i2, i3: i3, i4: i4, i5: i5
        )
        return (iface, warnings)
    }

    // MARK: - Peer

    private static func buildPeer(from section: INIParser.Section) throws -> AwgConfig.Peer {
        var publicKey: String? = nil
        var presharedKey: String? = nil
        var endpoint: (String, UInt16)? = nil
        var allowedIPs: [String] = []
        var keepalive: UInt16? = nil

        for entry in section.entries {
            let k = entry.key.lowercased()
            let v = entry.value
            switch k {
            case "publickey":      publicKey = v
            case "presharedkey":   presharedKey = v.isEmpty ? nil : v
            case "endpoint":       endpoint = try parseEndpoint(v)
            case "allowedips":     allowedIPs.append(contentsOf: splitList(v))
            case "persistentkeepalive": keepalive = try parseUInt16(v, key: "PersistentKeepalive")
            default:               continue
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

        return AwgConfig.Peer(
            publicKey: pk,
            presharedKey: presharedKey,
            endpointHost: ep.0,
            endpointPort: ep.1,
            allowedIPs: allowedIPs,
            persistentKeepalive: keepalive
        )
    }

    // MARK: - helpers

    private static func splitList(_ value: String) -> [String] {
        value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func parseInt(_ s: String, key: String) throws -> Int {
        guard let n = Int(s) else { throw AwgConfigError.invalidNumber(key: key, value: s) }
        return n
    }
    private static func parseUInt16(_ s: String, key: String) throws -> UInt16 {
        guard let n = UInt16(s) else { throw AwgConfigError.invalidNumber(key: key, value: s) }
        return n
    }
    private static func parseUInt32(_ s: String, key: String) throws -> UInt32 {
        guard let n = UInt32(s) else { throw AwgConfigError.invalidNumber(key: key, value: s) }
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
