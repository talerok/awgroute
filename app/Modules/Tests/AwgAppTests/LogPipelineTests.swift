import XCTest
import AwgDomain
@testable import AwgInfrastructure
@testable import AwgPresentation

/// Проверка того, что строки лога реально доезжают до UI.
///
/// Регрессия: при разделении `BackendController` подписка `LogViewModel` потеряла
/// вызывающего — `TunnelStore` дёргал `LogSource.start()` (это только ротация),
/// а поток строк никто не читал. Панель логов оставалась пустой.
final class LogPipelineTests: XCTestCase {

    private var file: URL!

    override func setUp() {
        super.setUp()
        file = FileManager.default.temporaryDirectory
            .appendingPathComponent("awgroute-log-test-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: file.path, contents: nil)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: file)
        super.tearDown()
    }

    private func append(_ line: String) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }

    func testFileLogSourceDeliversAppendedLines() async throws {
        let source = FileLogSource(fileURL: file)

        let received = expectation(description: "строка доехала")
        let task = Task {
            for await line in source.follow() where line.contains("hello") {
                received.fulfill()
                return
            }
        }
        // Tailer опрашивает файл; даём ему подхватить дескриптор.
        try await Task.sleep(for: .milliseconds(400))
        try append("hello from backend")

        await fulfillment(of: [received], timeout: 5)
        task.cancel()
    }

    @MainActor
    func testDoesNotFollowWhileTunnelIsStopped() async throws {
        // Главное изменение: пока туннеля нет, за файлом не следим вообще —
        // раньше опрос крутился всегда, даже когда писать в лог было некому.
        let source = FakeLogSource()
        _ = LogViewModel(source: source, fileURL: file, statusUpdates: { AsyncStream { $0.finish() } })
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(source.followCount, 0)
    }

    @MainActor
    func testFollowsWhileRunning() async throws {
        let source = FakeLogSource()
        let (stream, cont) = AsyncStream<TunnelStatus>.makeStream()
        let vm = LogViewModel(source: source, fileURL: file, statusUpdates: { stream })

        cont.yield(.running(pid: 1))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(source.followCount, 1)

        source.emit("from backend")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(vm.lines.contains("from backend"))
    }

    @MainActor
    func testUnfollowsAfterGraceAndMarksLast() async throws {
        let source = FakeLogSource()
        let (stream, cont) = AsyncStream<TunnelStatus>.makeStream()
        let vm = LogViewModel(source: source, fileURL: file,
                              statusUpdates: { stream }, gracePeriod: .milliseconds(300))

        cont.yield(.running(pid: 1))
        try await Task.sleep(for: .milliseconds(150))
        cont.yield(.stopped)

        // Пауза ещё идёт: залп «context canceled» должен успеть доехать.
        source.emit("context canceled")
        try await Task.sleep(for: .milliseconds(500))

        XCTAssertTrue(source.isCancelled, "после паузы подписка должна отцепиться")
        // Ключевое: отбивка стоит ПОСЛЕ шума, иначе шум выглядит как активность
        // уже после выключения.
        let noise = vm.lines.firstIndex(of: "context canceled")
        let marker = vm.lines.lastIndex { $0.contains("tunnel stopped") }
        XCTAssertNotNil(noise); XCTAssertNotNil(marker)
        XCTAssertLessThan(noise!, marker!)
    }

    @MainActor
    func testShowsHistoryWithoutFollowing() async throws {
        let source = FakeLogSource()
        source.history = ["прошлая сессия"]
        let vm = LogViewModel(source: source, fileURL: file, statusUpdates: { AsyncStream { $0.finish() } })
        XCTAssertEqual(vm.lines, ["прошлая сессия"])
        XCTAssertEqual(source.followCount, 0, "история — разовым чтением, без подписки")
    }
}

/// Подделка порта: позволяет проверить вью-модель без файловой системы.
private final class FakeLogSource: LogSource, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<String>.Continuation?
    private(set) var followCount = 0
    private(set) var isCancelled = false
    var history: [String] = []

    func lastFatal() -> String? { nil }
    func recentTail() -> [String] { history }

    func follow() -> AsyncStream<String> {
        lock.lock(); followCount += 1; lock.unlock()
        return AsyncStream { continuation in
            self.lock.lock(); self.continuation = continuation; self.lock.unlock()
            continuation.onTermination = { _ in
                self.lock.lock(); self.isCancelled = true; self.lock.unlock()
            }
        }
    }

    func emit(_ line: String) {
        lock.lock(); let c = continuation; lock.unlock()
        c?.yield(line)
    }
}

/// Отбивки по переходам состояния.
final class LogMarkerTests: XCTestCase {

    @MainActor
    private func makeSUT() -> (LogViewModel, FakeLogSource) {
        let source = FakeLogSource()
        let vm = LogViewModel(source: source,
                              fileURL: URL(fileURLWithPath: "/dev/null"),
                              statusUpdates: { AsyncStream { $0.finish() } },
                              gracePeriod: .milliseconds(50))
        return (vm, source)
    }

    @MainActor
    func testMarksConnectAndUp() async throws {
        let (vm, _) = makeSUT()
        vm.handle(.starting)
        vm.handle(.running(pid: 1))
        XCTAssertTrue(vm.lines[0].contains("connecting"))
        XCTAssertTrue(vm.lines[1].contains("tunnel up"))
    }

    @MainActor
    func testStoppingDoesNotMark() async throws {
        let (vm, _) = makeSUT()
        vm.handle(.stopping)
        // Отбивку ставим по факту остановки и только после паузы: иначе залп
        // «context canceled» окажется под ней.
        XCTAssertTrue(vm.lines.isEmpty)
    }

    @MainActor
    func testFailureIsMarkedWithReason() async throws {
        let (vm, _) = makeSUT()
        vm.handle(.failed("boom"))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(vm.lines.contains { $0.contains("boom") })
    }
}
