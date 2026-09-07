import Foundation
import AwgDomain
import Security

/// Тонкий клиент к Clash API, который выставляет amnezia-box на 127.0.0.1:9090.
public final class ClashAPI: TelemetrySource, @unchecked Sendable {
    public static let localhost = URL(string: "http://127.0.0.1:9090")!
    public let base: URL

    public init(base: URL = ClashAPI.localhost, secrets: ClashSecretProvider) {
        self.base = base
        self.secrets = secrets
    }

    /// Секрет текущего подключения: его выдал сценарий подключения при генерации
    /// конфига, здесь он только предъявляется.
    private let secrets: ClashSecretProvider

    private func authorized(_ request: inout URLRequest) {
        if let s = secrets.current {
            request.setValue("Bearer \(s)", forHTTPHeaderField: "Authorization")
        }
    }

    /// AsyncStream `(up, down)` в байтах/сек. Под капотом — WebSocket к `/traffic`.
    /// При отвалах — авто-реконнект каждые 2 сек.
    public func trafficStream() -> AsyncStream<(up: UInt64, down: UInt64)> {
        AsyncStream { cont in
            let task = Task {
                while !Task.isCancelled {
                    await self.runTrafficWS { up, down in
                        cont.yield((up, down))
                    }
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    private func runTrafficWS(yield: @escaping (UInt64, UInt64) -> Void) async {
        var comps = URLComponents(url: base.appendingPathComponent("traffic"), resolvingAgainstBaseURL: false)!
        comps.scheme = "ws"
        guard let url = comps.url else { return }
        let session = URLSession(configuration: .ephemeral)
        var request = URLRequest(url: url)
        authorized(&request)
        let task = session.webSocketTask(with: request)
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }
        while !Task.isCancelled {
            do {
                let msg = try await task.receive()
                let str: String
                switch msg {
                case .string(let s): str = s
                case .data(let d):   str = String(data: d, encoding: .utf8) ?? ""
                @unknown default:    continue
                }
                if let data = str.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let up = (obj["up"] as? NSNumber)?.uint64Value,
                   let down = (obj["down"] as? NSNumber)?.uint64Value
                {
                    yield(up, down)
                }
            } catch {
                return    // вернёмся — выше будет авто-реконнект
            }
        }
    }

    // MARK: - TelemetrySource

    public func traffic() -> AsyncStream<TrafficSample> {
        let raw = trafficStream()
        return AsyncStream { continuation in
            let task = Task {
                for await pair in raw { continuation.yield(TrafficSample(up: pair.up, down: pair.down)) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Внешний IP — признак того, что трафик действительно идёт через туннель.
    public func externalIP() async -> String? {
        for url in ["https://api.ipify.org", "https://ifconfig.me/ip"] {
            guard let u = URL(string: url) else { continue }
            var req = URLRequest(url: u)
            req.timeoutInterval = 10
            req.cachePolicy = .reloadIgnoringLocalCacheData
            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let ip = String(data: data, encoding: .utf8)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !ip.isEmpty, ip.count <= 45,
                  ip.allSatisfy({ $0.isHexDigit || $0 == "." || $0 == ":" }) else { continue }
            return ip
        }
        return nil
    }
}
