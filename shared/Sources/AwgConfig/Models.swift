import Foundation

/// Распарсенный AmneziaWG `.conf` файл.
///
/// Источник правды по полям AWG-обфускации — `backend/src/option/awg.go`.
/// Поля `j1-j3`, `itime`, прочие "неизвестные ключи" из `.conf` сохраняются
/// в `warnings` и игнорируются генератором.
public struct AwgConfig: Equatable, Sendable, Codable {
    public var interface: Interface
    public var peers: [Peer]
    /// Ключи из `[Interface]`, которых нет в нашей схеме — runtime-only, для UI/логов.
    /// Не сериализуется (Codable) и не учитывается в Equatable: профиль идентичен
    /// независимо от того, осталась ли пара лишних строк в исходном .conf.
    public var warnings: [String] = []

    public init(interface: Interface, peers: [Peer], warnings: [String] = []) {
        self.interface = interface
        self.peers = peers
        self.warnings = warnings
    }

    enum CodingKeys: String, CodingKey { case interface, peers }

    public static func == (lhs: AwgConfig, rhs: AwgConfig) -> Bool {
        lhs.interface == rhs.interface && lhs.peers == rhs.peers
    }

    public struct Interface: Equatable, Sendable, Codable {
        // ── базовое WireGuard ──
        public var address: [String]            // ["10.8.0.2/24", "fd00::2/64"]
        public var privateKey: String           // base64
        public var dns: [String]                // ["1.1.1.1", "1.0.0.1"]
        public var mtu: UInt32?
        public var listenPort: UInt16?

        // ── AmneziaWG обфускация ──
        public var jc: Int?
        public var jmin: Int?
        public var jmax: Int?
        public var s1: Int?
        public var s2: Int?
        public var s3: Int?
        public var s4: Int?
        public var h1: String?
        public var h2: String?
        public var h3: String?
        public var h4: String?
        public var i1: String?
        public var i2: String?
        public var i3: String?
        public var i4: String?
        public var i5: String?

        public init(
            address: [String],
            privateKey: String,
            dns: [String] = [],
            mtu: UInt32? = nil,
            listenPort: UInt16? = nil,
            jc: Int? = nil, jmin: Int? = nil, jmax: Int? = nil,
            s1: Int? = nil, s2: Int? = nil, s3: Int? = nil, s4: Int? = nil,
            h1: String? = nil, h2: String? = nil, h3: String? = nil, h4: String? = nil,
            i1: String? = nil, i2: String? = nil, i3: String? = nil, i4: String? = nil, i5: String? = nil
        ) {
            self.address = address
            self.privateKey = privateKey
            self.dns = dns
            self.mtu = mtu
            self.listenPort = listenPort
            self.jc = jc; self.jmin = jmin; self.jmax = jmax
            self.s1 = s1; self.s2 = s2; self.s3 = s3; self.s4 = s4
            self.h1 = h1; self.h2 = h2; self.h3 = h3; self.h4 = h4
            self.i1 = i1; self.i2 = i2; self.i3 = i3; self.i4 = i4; self.i5 = i5
        }
    }

    public struct Peer: Equatable, Sendable, Codable {
        public var publicKey: String                 // base64
        public var presharedKey: String?             // base64
        public var endpointHost: String              // IP или domain
        public var endpointPort: UInt16
        public var allowedIPs: [String]              // ["0.0.0.0/0", "::/0"]
        public var persistentKeepalive: UInt16?

        public init(
            publicKey: String,
            presharedKey: String? = nil,
            endpointHost: String,
            endpointPort: UInt16,
            allowedIPs: [String],
            persistentKeepalive: UInt16? = nil
        ) {
            self.publicKey = publicKey
            self.presharedKey = presharedKey
            self.endpointHost = endpointHost
            self.endpointPort = endpointPort
            self.allowedIPs = allowedIPs
            self.persistentKeepalive = persistentKeepalive
        }
    }
}

public enum AwgConfigError: Error, Equatable, Sendable {
    case missingSection(String)            // нет [Interface] или [Peer]
    case missingRequiredKey(section: String, key: String)
    case malformedLine(line: String, lineNumber: Int)
    case invalidEndpoint(String)           // host:port не разбирается
    case invalidNumber(key: String, value: String)
    case invalidPort(String)
}
