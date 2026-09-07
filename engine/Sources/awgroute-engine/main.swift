import Foundation
import Darwin
import AwgProtocol

// Движок AwgRoute: LaunchDaemon, владеющий процессом backend'а, системным DNS
// и конфигом. GUI — его клиент, а не наоборот: движок переживает перезапуск
// приложения и подхватывает работающий туннель обратно.
//
// Владелец приходит через env из plist, который заполняет установщик.

guard let ownerUIDString = ProcessInfo.processInfo.environment["AWGROUTE_OWNER_UID"],
      let ownerUID = UInt32(ownerUIDString),
      let ownerUser = ProcessInfo.processInfo.environment["AWGROUTE_OWNER_USER"],
      !ownerUser.isEmpty,
      ownerUser != ".", ownerUser != "..",
      // Имя пользователя попадает в пути — не пускаем слэши и спецсимволы.
      ownerUser.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." })
else {
    Logger.shared.error("missing or invalid AWGROUTE_OWNER_UID / AWGROUTE_OWNER_USER env")
    exit(1)
}

Logger.shared.info("starting \(EngineProtocol.Names.binary) pid=\(getpid()) "
                   + "owner=\(ownerUser)(\(ownerUID)) protocol=v\(EngineProtocol.version)")

let server = SocketServer(ownerUID: ownerUID)

let backend = BackendProcess(
    binary: "/Applications/AwgRoute.app/Contents/Resources/amnezia-box",
    pidFile: EngineProtocol.Paths.pidFile,
    ownerUID: ownerUID,
    ownerUser: ownerUser
)

let session = TunnelSession(
    backend: backend,
    dns: SystemDNS(),
    vault: EphemeralConfigVault(),
    broadcaster: server
)

// Подхватываем туннель, переживший перезапуск движка, и снимаем осиротевший
// DNS-override, если backend его не пережил.
session.adopt()

server.attach(dispatcher: CommandDispatcher(session: session))

// Сторож: backend может умереть сам. Расхождение уезжает подписчикам событием —
// GUI узнаёт о падении, ничего не опрашивая.
let watchdog = Thread {
    while true {
        Thread.sleep(forTimeInterval: 3)
        session.reconcile()
    }
}
watchdog.qualityOfService = .utility
watchdog.start()

server.run()
