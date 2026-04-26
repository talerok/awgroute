import Foundation

/// Кольцевой буфер последних N строк лога + multicast подписчикам.
actor LogBuffer {
    private var lines: [String] = []
    private let capacity: Int
    private var subs: [UUID: (String) -> Void] = [:]

    init(capacity: Int) {
        self.capacity = capacity
        self.lines.reserveCapacity(capacity)
    }

    func append(_ line: String) {
        if lines.count >= capacity { lines.removeFirst() }
        lines.append(line)
        for cb in subs.values { cb(line) }
    }

    func snapshot() -> [String] { lines }

    /// Подписаться. Колбэк сначала получает snapshot существующих строк,
    /// затем все новые. Возвращает функцию-отписку.
    nonisolated func subscribe(_ cb: @escaping (String) -> Void) -> () -> Void {
        let id = UUID()
        Task { await self._subscribeAndReplay(id: id, cb: cb) }
        return { Task { await self._unsubscribe(id: id) } }
    }

    private func _subscribeAndReplay(id: UUID, cb: @escaping (String) -> Void) {
        for s in lines { cb(s) }
        subs[id] = cb
    }
    private func _unsubscribe(id: UUID) { subs.removeValue(forKey: id) }
}
