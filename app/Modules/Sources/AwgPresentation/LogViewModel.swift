import Foundation
import AwgDomain

/// Строки лога для UI.
///
/// Владеет ОДНИМ правилом целиком: следить за файлом, пока туннель поднят, плюс
/// короткая пауза после остановки — чтобы поймать предсмертный залп backend'а
/// (при штатном Disconnect он рвёт все открытые соединения и пишет около сотни строк).
///
/// Раньше это правило не существовало: подписка начиналась в `init` и не кончалась
/// никогда, опрашивая файл каждые 200 мс даже когда писать в него было некому.
/// А отбивки в лог ставились отдельной проводкой из корня композиции — то есть
/// «когда» и «что» жили в разных местах.
@MainActor
public final class LogViewModel: ObservableObject {

    @Published public private(set) var lines: [String] = []

    private let source: LogSource
    private var followTask: Task<Void, Never>?
    private var lifecycleTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?

    private static let maxLines = 5_000
    /// Сколько ждать после остановки, прежде чем отцепиться. Залп приходит уже после
    /// того, как движок ответил на stop, поэтому обрывать чтение сразу нельзя.
    private let gracePeriod: Duration

    /// Путь к файлу — только чтобы кнопка «Open file» могла его показать.
    public let fileURL: URL

    public init(source: LogSource,
                fileURL: URL,
                statusUpdates: @escaping @Sendable () -> AsyncStream<TunnelStatus>,
                gracePeriod: Duration = .seconds(3)) {
        self.source = source
        self.fileURL = fileURL
        self.gracePeriod = gracePeriod

        // История прошлой сессии — разовым чтением, без подписки. Иначе после
        // запуска приложения панель пуста и непонятно, чем кончился прошлый раз.
        lines = source.recentTail()

        lifecycleTask = Task { [weak self] in
            for await status in statusUpdates() {
                self?.handle(status)
            }
        }
    }

    deinit {
        followTask?.cancel()
        lifecycleTask?.cancel()
        stopTask?.cancel()
    }

    public func clear() { lines.removeAll(keepingCapacity: false) }

    /// Отбивка в панели: граница между сессиями и между шумом остановки и тишиной.
    public func mark(_ text: String) {
        append("────────  \(text)  ────────")
    }

    // MARK: - Правило

    func handle(_ status: TunnelStatus) {
        switch status {
        case .starting:
            stopTask?.cancel(); stopTask = nil
            mark("connecting")
            follow()
        case .running:
            stopTask?.cancel(); stopTask = nil
            mark("tunnel up")
            follow()
        case .stopping:
            break   // отцепляемся по факту остановки, не по началу
        case .stopped:
            scheduleUnfollow(marking: "tunnel stopped")
        case .failed(let reason):
            scheduleUnfollow(marking: "failed: \(reason)")
        }
    }

    private func follow() {
        guard followTask == nil else { return }
        followTask = Task { [weak self] in
            guard let stream = self?.source.follow() else { return }
            for await line in stream {
                guard let self else { return }
                self.append(line)
            }
        }
    }

    /// Отбивку ставим ПОСЛЕ паузы, а не сразу.
    ///
    /// Залп «context canceled» приходит уже после того, как статус стал `.stopped`.
    /// Поставь отбивку сразу — и шум окажется под ней, то есть будет выглядеть как
    /// активность после выключения. Ровно та путаница, ради которой всё и делалось.
    private func scheduleUnfollow(marking text: String) {
        guard stopTask == nil else { return }
        stopTask = Task { [weak self] in
            guard let grace = self?.gracePeriod else { return }
            try? await Task.sleep(for: grace)
            guard let self, !Task.isCancelled else { return }
            self.followTask?.cancel()
            self.followTask = nil
            self.mark(text)
            self.stopTask = nil
        }
    }

    private func append(_ line: String) {
        if lines.count >= Self.maxLines { lines.removeFirst(1_000) }
        lines.append(line)
    }
}
