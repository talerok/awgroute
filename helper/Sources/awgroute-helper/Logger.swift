import Foundation
import Darwin

/// Логгер с rotation по размеру. Пишет в /var/log/awgroute-helper.log + stderr (launchd подхватит).
final class Logger {

    static let shared = Logger(path: "/var/log/awgroute-helper.log", maxBytes: 5 * 1024 * 1024)

    private let path: String
    private let maxBytes: UInt64
    private let queue = DispatchQueue(label: "dev.awgroute.helper.logger")
    private var handle: FileHandle?
    private let isoFormatter: ISO8601DateFormatter

    init(path: String, maxBytes: UInt64) {
        self.path = path
        self.maxBytes = maxBytes
        self.isoFormatter = ISO8601DateFormatter()
        openHandle()
    }

    func info(_ msg: String)  { log("INFO ", msg) }
    func warn(_ msg: String)  { log("WARN ", msg) }
    func error(_ msg: String) { log("ERROR", msg) }

    private func log(_ level: String, _ msg: String) {
        queue.sync {
            let line = "\(isoFormatter.string(from: Date())) \(level) \(msg)\n"
            guard let data = line.data(using: .utf8) else { return }
            FileHandle.standardError.write(data)
            handle?.write(data)
            rotateIfNeeded()
        }
    }

    private func openHandle() {
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(
                atPath: path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        }
        handle = FileHandle(forWritingAtPath: path)
        _ = try? handle?.seekToEnd()
    }

    private func rotateIfNeeded() {
        guard
            let attrs = try? FileManager.default.attributesOfItem(atPath: path),
            let size = attrs[.size] as? UInt64,
            size > maxBytes
        else { return }
        try? handle?.close()
        let rotated = path + ".1"
        try? FileManager.default.removeItem(atPath: rotated)
        try? FileManager.default.moveItem(atPath: path, toPath: rotated)
        openHandle()
    }
}
