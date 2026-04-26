import Foundation

/// Простейший tail -f для одного файла.
/// Polling каждые 200 мс. Файл может появиться позже, чем мы начали смотреть —
/// тогда ждём. При rotate (mtime внезапно сбросилось / inode сменился) — переоткрываем.
enum LogTailer {

    /// Цикл живёт пока Task не отменена.
    static func tail(file url: URL, onLine: @escaping (String) -> Void) async {
        let path = url.path
        let fm = FileManager.default
        var handle: FileHandle? = nil
        var lastInode: UInt64 = 0
        var pendingPartial = ""

        defer { try? handle?.close() }

        while !Task.isCancelled {
            // Открыть/переоткрыть файл если изменился inode (или ещё не открыт)
            let attrs = try? fm.attributesOfItem(atPath: path)
            let inode = (attrs?[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            if handle == nil || inode != lastInode {
                try? handle?.close()
                handle = nil
                if let h = try? FileHandle(forReadingFrom: url) {
                    handle = h
                    lastInode = inode
                    // Если стартуем впервые и файл уже большой — прыгнуть к концу,
                    // чтобы не залить UI старыми строками.
                    if let end = try? h.seekToEnd(), end > 64 * 1024 {
                        try? h.seek(toOffset: end - 4096)
                    }
                }
            }

            if let h = handle {
                if let data = try? h.read(upToCount: 64 * 1024), !data.isEmpty {
                    if let s = String(data: data, encoding: .utf8) {
                        pendingPartial += s
                        while let nl = pendingPartial.firstIndex(of: "\n") {
                            let line = String(pendingPartial[..<nl])
                            pendingPartial.removeSubrange(...nl)
                            if !line.isEmpty { onLine(line) }
                        }
                    }
                    continue   // сразу следующая итерация — данных может быть ещё
                }
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }
}
