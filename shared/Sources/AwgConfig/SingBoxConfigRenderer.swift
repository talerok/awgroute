import Foundation
import AwgDomain

/// Реализация `ConfigRendering` для backend'а amnezia-box (форк sing-box).
///
/// Это адаптер: всё знание об именах полей backend'а заканчивается здесь. Домен
/// оперирует `AwgConfig` и `RoutingRules` и не подозревает, что под ним sing-box, —
/// поэтому смена backend'а не задевает сценарии.
public struct SingBoxConfigRenderer: ConfigRendering {
    public init() {}

    public func render(config: AwgConfig, rules: RoutingRules?, options: RenderOptions) throws -> Data {
        var opts = AwgJSONGenerator.Options()
        opts.endpointTag = "vpn"
        opts.remoteDNSServer = options.remoteDNSServer
        opts.cacheFilePath = options.cacheFilePath
        opts.clashAPISecret = options.clashAPISecret

        // rules.json — это секция `route` ПЛЮС необязательная `dns`. Разделение
        // делается здесь, а не в домене: это особенность схемы backend'а.
        let parsed = rules.flatMap { Self.parseObject($0.text) }
        return try AwgJSONGenerator.fullConfigJSON(
            from: config,
            options: opts,
            userRoute: parsed,
            userDNS: AwgJSONGenerator.userDNSSection(from: parsed)
        )
    }

    public func validate(rules: RoutingRules) -> RulesValidation {
        let data = Data(rules.text.utf8)
        do {
            let obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            guard obj is [String: Any] else { return .invalid("Top-level must be an object.") }
            return .ok
        } catch {
            return .invalid(error.localizedDescription)
        }
    }

    static func parseObject(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]))
            as? [String: Any]
    }
}
