import Foundation

/// Тонкий клиент к Clash API, который выставляет amnezia-box на 127.0.0.1:9090.
final class ClashAPI {
    private static let localhost = URL(string: "http://127.0.0.1:9090")!
    let base: URL
    init(base: URL = ClashAPI.localhost) { self.base = base }

    struct Version: Decodable { let version: String; let premium: Bool? }

    func version() async throws -> Version {
        let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("version"))
        return try JSONDecoder().decode(Version.self, from: data)
    }

    /// AsyncStream `(up, down)` в байтах/сек. Под капотом — WebSocket к `/traffic`.
    /// При отвалах — авто-реконнект каждые 2 сек.
    func trafficStream() -> AsyncStream<(up: UInt64, down: UInt64)> {
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
        let task = session.webSocketTask(with: url)
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
}
