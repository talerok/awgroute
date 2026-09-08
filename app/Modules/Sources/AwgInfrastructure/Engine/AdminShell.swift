import Foundation
import AppKit

/// Выполнение shell-команды с правами администратора через AppleScript.
///
/// Общая для установщика и управления движком: обе операции требуют root и обе
/// показывают один системный промпт пароля. Раньше это жило приватным методом
/// внутри установщика, и второму потребителю пришлось бы дублировать.
enum AdminShell {

    enum Failure: Error, CustomStringConvertible {
        case cancelled
        case scriptFailed(String)

        var description: String {
            switch self {
            case .cancelled:            return "cancelled by user"
            case .scriptFailed(let m):  return m
            }
        }
    }

    static func run(_ bash: String) async throws {
        let escaped = bash
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            // AppleScript с GUI-промптом нельзя выполнять на main thread.
            DispatchQueue.global(qos: .userInitiated).async {
                var err: NSDictionary?
                guard let appleScript = NSAppleScript(source: script) else {
                    cont.resume(throwing: Failure.scriptFailed("NSAppleScript init failed"))
                    return
                }
                _ = appleScript.executeAndReturnError(&err)
                guard let err else { return cont.resume(returning: ()) }
                // -128 = errAEEventCanceled: пользователь нажал Cancel в диалоге пароля.
                let code = err[NSAppleScript.errorNumber] as? Int ?? 0
                if code == -128 {
                    cont.resume(throwing: Failure.cancelled)
                } else {
                    cont.resume(throwing: Failure.scriptFailed(
                        err[NSAppleScript.errorMessage] as? String ?? "code=\(code)"))
                }
            }
        }
    }
}
