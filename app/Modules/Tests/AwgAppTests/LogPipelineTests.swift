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
        source.start()

        let received = expectation(description: "строка доехала")
        let task = Task {
            for await line in source.lines() where line.contains("hello") {
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
    func testViewModelCollectsWithoutExplicitStart() async throws {
        // Ключевое: подписка должна работать сразу после init, без внешнего start().
        let source = FakeLogSource()
        let vm = LogViewModel(source: source, fileURL: file)

        source.emit("first")
        source.emit("second")
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(vm.lines, ["first", "second"])
    }

    @MainActor
    func testClearEmptiesBuffer() async throws {
        let source = FakeLogSource()
        let vm = LogViewModel(source: source, fileURL: file)
        source.emit("x")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(vm.lines.isEmpty)
        vm.clear()
        XCTAssertTrue(vm.lines.isEmpty)
    }
}

/// Подделка порта: позволяет проверить вью-модель без файловой системы.
private final class FakeLogSource: LogSource, @unchecked Sendable {
    private var continuation: AsyncStream<String>.Continuation?
    private let lock = NSLock()
    private var pending: [String] = []

    func start() {}
    func lastFatal() -> String? { nil }

    func lines() -> AsyncStream<String> {
        AsyncStream { continuation in
            self.lock.lock()
            self.continuation = continuation
            let queued = self.pending
            self.pending = []
            self.lock.unlock()
            queued.forEach { continuation.yield($0) }
        }
    }

    func emit(_ line: String) {
        lock.lock()
        let c = continuation
        if c == nil { pending.append(line) }
        lock.unlock()
        c?.yield(line)
    }
}
