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
        // Накопитель сырых байт — UTF-8 multibyte char может быть разрезан между
        // двумя read'ами (или между chunk'ами лога). Нельзя декодировать сразу
        // в String до того как пришёл terminator (\n) — иначе теряем хвост.
        var pending = Data()

        defer { try? handle?.close() }

        while !Task.isCancelled {
            // Открыть/переоткрыть файл если изменился inode (или ещё не открыт)
            let attrs = try? fm.attributesOfItem(atPath: path)
            let inode = (attrs?[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            if handle == nil || inode != lastInode {
                try? handle?.close()
                handle = nil
                pending.removeAll(keepingCapacity: true)
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
                    pending.append(data)
                    // Резать на строки на уровне Data — байт 0x0A однозначен в UTF-8
                    // (multibyte continuation байты ВСЕГДА имеют старший бит 1).
                    let nl: UInt8 = 0x0A
                    while let nlIdx = pending.firstIndex(of: nl) {
                        let lineData = pending.prefix(upTo: nlIdx)
                        pending.removeSubrange(...nlIdx)
                        if let line = String(data: lineData, encoding: .utf8) {
                            if !line.isEmpty { onLine(line) }
                        } else {
                            // Гарантированно невалидный UTF-8 (например, обрезанный
                            // chunk на границе старого файла после ротации). Декодим
                            // с заменой битых байт на U+FFFD, лишь бы не терять строку.
                            let line = String(decoding: lineData, as: UTF8.self)
                            if !line.isEmpty { onLine(line) }
                        }
                    }
                    // Защита от unbounded роста pending: одна строка > 1MB —
                    // сбросить, скорее всего лог битый или поток без \n.
                    if pending.count > 1 * 1024 * 1024 {
                        pending.removeAll(keepingCapacity: false)
                    }
                    continue   // сразу следующая итерация — данных может быть ещё
                }
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }
}
