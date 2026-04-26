import Foundation

/// Кольцевой буфер последних N строк лога + multicast подписчикам.
actor LogBuffer {
    private var lines: [String] = []
    private let capacity: Int
    private var subs: [UUID: (String) -> Void] = [:]
    /// IDs, для которых unsubscribe пришёл раньше чем _subscribeAndReplay выполнился
    /// на акторе. Swift Concurrency не гарантирует FIFO между независимыми Task'ами,
    /// поэтому вместо надежды на порядок явно отслеживаем «уже отменено».
    private var pendingCancels: Set<UUID> = []

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
        return { Task { await self._cancelSubscription(id: id) } }
    }

    private func _subscribeAndReplay(id: UUID, cb: @escaping (String) -> Void) {
        if pendingCancels.remove(id) != nil { return }  // уже отменено до регистрации
        for s in lines { cb(s) }
        subs[id] = cb
    }

    private func _cancelSubscription(id: UUID) {
        if subs.removeValue(forKey: id) == nil {
            // _subscribeAndReplay ещё не выполнился — помечаем как отменённый
            pendingCancels.insert(id)
        }
    }
}
