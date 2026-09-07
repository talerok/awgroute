import Foundation
import AwgDomain

/// Текущий внешний IP, аптайм соединения, скорость RX/TX.
@MainActor
public final class Telemetry: ObservableObject {

    @Published public private(set) var externalIP: String? = nil
    @Published public private(set) var uptime: TimeInterval = 0
    @Published public private(set) var upBps: UInt64 = 0
    @Published public private(set) var downBps: UInt64 = 0

    private var connectedAt: Date? = nil
    private var trafficTask: Task<Void, Never>? = nil
    private var ipTask: Task<Void, Never>? = nil
    private var uptimeTimer: Task<Void, Never>? = nil
    private let source: TelemetrySource

    public init(source: TelemetrySource) {
        self.source = source
    }

    public func start() {
        connectedAt = Date()
        uptime = 0
        externalIP = nil
        startUptimeTimer()
        startTrafficStream()
        // Авто-обновление: ждём пока туннель полностью поднимется + DNS прогреется.
        refreshExternalIP(initialDelay: 4)
    }

    public func stop() {
        trafficTask?.cancel(); trafficTask = nil
        ipTask?.cancel(); ipTask = nil
        uptimeTimer?.cancel(); uptimeTimer = nil
        connectedAt = nil
        upBps = 0; downBps = 0
        externalIP = nil
        uptime = 0
    }

    private func startUptimeTimer() {
        uptimeTimer?.cancel()
        let start = connectedAt ?? Date()
        uptimeTimer = Task { [weak self] in
            // 1 Hz: UI отображает уптайм с точностью до секунды,
            // частить SwiftUI re-render'ами нет смысла.
            while !Task.isCancelled {
                self?.uptime = Date().timeIntervalSince(start)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
    private func startTrafficStream() {
        trafficTask?.cancel()
        let stream = source.traffic()
        trafficTask = Task { [weak self] in
            for await sample in stream {
                self?.upBps = sample.up
                self?.downBps = sample.down
            }
        }
    }

    /// `initialDelay` > 0 — для автозапуска после connect (даём DNS прогреться).
    /// Кнопка Refresh в UI вызывает без задержки.
    /// `initialDelay` > 0 — для автозапуска после connect: даём DNS прогреться.
    public func refreshExternalIP(initialDelay: TimeInterval = 0) {
        ipTask?.cancel()
        ipTask = Task { [weak self] in
            if initialDelay > 0 { try? await Task.sleep(for: .seconds(initialDelay)) }
            guard let ip = await self?.source.externalIP() else { return }
            self?.externalIP = ip
        }
    }

    static func formatBytesPerSec(_ bps: UInt64) -> String {
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var v = Double(bps), i = 0
        while v >= 1024, i < units.count - 1 { v /= 1024; i += 1 }
        return String(format: "%.1f %@", v, units[i])
    }
    static func formatUptime(_ t: TimeInterval) -> String {
        let s = Int(t)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }
}
