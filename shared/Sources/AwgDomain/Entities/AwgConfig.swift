import Foundation

/// Числовой параметр AmneziaWG 3.x: скаляр (`25`) либо диапазон (`25-35`).
///
/// В AWG 3.0 тайминги и `PersistentKeepalive` стали `uint32,range` — устройство
/// сэмплирует свежее значение внутри диапазона каждый раз, когда взводит таймер.
/// Это и есть смысл параметра: фиксированные тайминги — фингерпринт WireGuard.
/// Поэтому диапазон НЕ схлопывается, а едет в backend дословно.
public struct AwgRange: Equatable, Hashable, Sendable, CustomStringConvertible {
    public let lower: UInt32
    public let upper: UInt32

    public init(_ value: UInt32) {
        self.init(lower: value, upper: value)
    }

    private init(lower: UInt32, upper: UInt32) {
        self.lower = lower
        self.upper = upper
    }

    /// `"25"` или `"25-35"` (пробелы вокруг дефиса допускаются). nil если не разбирается.
    public init?(_ raw: String) {
        let parts = raw.split(separator: "-", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        switch parts.count {
        case 1:
            guard let v = UInt32(parts[0]) else { return nil }
            self.init(v)
        case 2:
            guard let lo = UInt32(parts[0]), let hi = UInt32(parts[1]), hi >= lo else { return nil }
            self.init(lower: lo, upper: hi)
        default:
            return nil
        }
    }

    public var isRange: Bool { upper > lower }

    /// Ровно то, что уходит в JSON-конфиг backend'а.
    public var description: String { isRange ? "\(lower)-\(upper)" : "\(lower)" }
}

extension AwgRange: Codable {
    /// Профили, сохранённые до перехода на AWG 3.x, хранят скаляр числом —
    /// декодируем обе формы, иначе при апгрейде приложения все профили на диске
    /// перестали бы читаться. Пишем всегда строкой.
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(UInt32.self) {
            self.init(n)
            return
        }
        let s = try c.decode(String.self)
        guard let parsed = AwgRange(s) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "not a number or \"min-max\" range: \(s)")
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

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

        // ── AmneziaWG 3.x ──
        /// base64, как в `.conf`. Backend сам переводит в hex для UAPI.
        /// Требует S1-S4 >= 12 — иначе backend откажется стартовать.
        public var headerProtectionKey: String?
        public var contentPaddingAddition: AwgRange?
        public var rekeyAfterTime: AwgRange?
        public var rekeyTimeout: AwgRange?
        public var rejectAfterTime: AwgRange?
        public var keepaliveTimeout: AwgRange?
        public var maxHandshakeAttempts: AwgRange?

        public init(
            address: [String],
            privateKey: String,
            dns: [String] = [],
            mtu: UInt32? = nil,
            listenPort: UInt16? = nil,
            jc: Int? = nil, jmin: Int? = nil, jmax: Int? = nil,
            s1: Int? = nil, s2: Int? = nil, s3: Int? = nil, s4: Int? = nil,
            h1: String? = nil, h2: String? = nil, h3: String? = nil, h4: String? = nil,
            i1: String? = nil, i2: String? = nil, i3: String? = nil, i4: String? = nil, i5: String? = nil,
            headerProtectionKey: String? = nil,
            contentPaddingAddition: AwgRange? = nil,
            rekeyAfterTime: AwgRange? = nil,
            rekeyTimeout: AwgRange? = nil,
            rejectAfterTime: AwgRange? = nil,
            keepaliveTimeout: AwgRange? = nil,
            maxHandshakeAttempts: AwgRange? = nil
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
            self.headerProtectionKey = headerProtectionKey
            self.contentPaddingAddition = contentPaddingAddition
            self.rekeyAfterTime = rekeyAfterTime
            self.rekeyTimeout = rekeyTimeout
            self.rejectAfterTime = rejectAfterTime
            self.keepaliveTimeout = keepaliveTimeout
            self.maxHandshakeAttempts = maxHandshakeAttempts
        }
    }

    public struct Peer: Equatable, Sendable, Codable {
        public var publicKey: String                 // base64
        public var presharedKey: String?             // base64
        public var endpointHost: String              // IP или domain
        public var endpointPort: UInt16
        public var allowedIPs: [String]              // ["0.0.0.0/0", "::/0"]
        public var persistentKeepalive: AwgRange?

        public init(
            publicKey: String,
            presharedKey: String? = nil,
            endpointHost: String,
            endpointPort: UInt16,
            allowedIPs: [String],
            persistentKeepalive: AwgRange? = nil
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
