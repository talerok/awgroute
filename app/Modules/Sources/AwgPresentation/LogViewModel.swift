import Foundation
import AwgDomain

/// Строки лога для UI. Знает только порт `LogSource` — ни про файлы, ни про ротацию.
@MainActor
public final class LogViewModel: ObservableObject {

    @Published public private(set) var lines: [String] = []

    private let source: LogSource
    private var consumeTask: Task<Void, Never>?
    private static let maxLines = 5_000

    /// Путь к лог-файлу — только чтобы кнопка «Open file» могла его показать.
    /// Приходит снаружи: Presentation не должна знать, где он лежит.
    public let fileURL: URL

    public init(source: LogSource, fileURL: URL) {
        self.source = source
        self.fileURL = fileURL
        // Подписываемся сразу.
        //
        // Раньше чтение начинал `BackendController` в своём init; когда он разошёлся
        // на части, у `start()` не осталось вызывающего — `TunnelStore` дёргает
        // `LogSource.start()`, а это только ротация. Панель логов оставалась пустой.
        //
        // Лениво стартовать нечего: смысл этого объекта — показывать лог, и он
        // должен наполняться ещё до первого Connect, чтобы была видна причина
        // неудачного старта.
        start()
    }

    deinit { consumeTask?.cancel() }

    public func start() {
        guard consumeTask == nil else { return }
        source.start()
        consumeTask = Task { [weak self] in
            guard let stream = self?.source.lines() else { return }
            for await line in stream {
                guard let self else { return }
                if self.lines.count >= Self.maxLines { self.lines.removeFirst(1_000) }
                self.lines.append(line)
            }
        }
    }

    public func clear() { lines.removeAll(keepingCapacity: false) }
}
