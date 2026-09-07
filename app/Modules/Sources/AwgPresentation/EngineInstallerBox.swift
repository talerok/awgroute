import Foundation
import AwgDomain

/// Обёртка порта `EngineInstalling` для передачи через `environmentObject`.
///
/// SwiftUI умеет прокидывать только классы-`ObservableObject`, а порт — протокол.
/// Коробка существует ровно поэтому и ничего больше не делает.
@MainActor
public final class EngineInstallerBox: ObservableObject {
    public let installer: EngineInstalling
    public init(_ installer: EngineInstalling) { self.installer = installer }
}
