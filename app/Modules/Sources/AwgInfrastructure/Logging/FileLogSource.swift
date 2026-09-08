import Foundation
import AwgDomain

/// Реализация `LogSource`: хвост лог-файла backend'а плюс ротация.
///
/// Ротация одна на все случаи — переименованием. `truncate` на месте не меняет inode,
/// поэтому tailer его не замечал, и панель логов замирала навсегда.
public final class FileLogSource: LogSource, @unchecked Sendable {

    private let fileURL: URL
    private let rotationLock = NSLock()
    private var rotationTask: Task<Void, Never>?

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    deinit { rotationTask?.cancel() }

    /// Следование начинается вместе с ротацией и заканчивается вместе с потоком:
    /// пока никто не читает, фоновых таймеров нет вообще.
    public func follow() -> AsyncStream<String> {
        rotateIfNeeded()
        startRotationTimer()
        return AsyncStream { continuation in
            let task = Task.detached(priority: .utility) { [fileURL] in
                await LogTailer.tail(file: fileURL) { continuation.yield($0) }
                continuation.finish()
            }
            continuation.onTermination = { [weak self] _ in
                task.cancel()
                self?.stopRotationTimer()
            }
        }
    }

    /// Хвост файла разово — чтобы показать историю прошлой сессии, не подписываясь.
    public func recentTail(maxBytes: Int = 64 * 1024) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let tail = UInt64(min(Int(size), maxBytes))
        try? handle.seek(toOffset: size - tail)
        guard let data = try? handle.read(upToCount: Int(tail)) else { return [] }
        var lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        // Первая строка почти наверняка обрезана посередине.
        if size > tail, !lines.isEmpty { lines.removeFirst() }
        return lines
    }

    public func recentTail() -> [String] { recentTail(maxBytes: 64 * 1024) }

    private func startRotationTimer() {
        rotationLock.lock(); defer { rotationLock.unlock() }
        guard rotationTask == nil else { return }
        rotationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
                self?.rotateIfNeeded(maxBytes: 10 * 1024 * 1024)
            }
        }
    }

    private func stopRotationTimer() {
        rotationLock.lock(); defer { rotationLock.unlock() }
        rotationTask?.cancel()
        rotationTask = nil
    }

    public func lastFatal() -> String? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let tail = UInt64(min(Int(size), 64 * 1024))
        try? handle.seek(toOffset: size - tail)
        guard let data = try? handle.read(upToCount: Int(tail)),
              let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").reversed() where line.contains("FATAL") {
            let cleaned = String(line).replacingOccurrences(
                of: "\u{1b}\\[[0-9;]*m", with: "", options: .regularExpression)
            return cleaned.count > 250 ? String(cleaned.prefix(250)) + "…" : cleaned
        }
        return nil
    }

    private func rotateIfNeeded(maxBytes: UInt64 = 5 * 1024 * 1024) {
        rotationLock.lock(); defer { rotationLock.unlock() }
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? UInt64, size > maxBytes else { return }
        let rotated = fileURL.path + ".1"
        try? fm.removeItem(atPath: rotated)
        try? fm.moveItem(atPath: fileURL.path, toPath: rotated)
    }
}
