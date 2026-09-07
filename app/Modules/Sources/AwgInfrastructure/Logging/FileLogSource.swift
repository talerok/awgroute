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

    public func start() {
        rotateIfNeeded()
        guard rotationTask == nil else { return }
        rotationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
                self?.rotateIfNeeded(maxBytes: 10 * 1024 * 1024)
            }
        }
    }

    public func lines() -> AsyncStream<String> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .utility) { [fileURL] in
                await LogTailer.tail(file: fileURL) { continuation.yield($0) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
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
