import Foundation
import Darwin

// Запускается launchd-демоном из /Library/LaunchDaemons/com.awgroute.helper.plist.
// Получает listening Unix socket по socket activation (`launch_activate_socket`).
// Принимает JSON-команды от UI-приложения, управляет subprocess'ом amnezia-box.
//
// Все пути hardcoded. Запускаемый бинарь — только /Applications/AwgRoute.app/Contents/Resources/amnezia-box.
// Owner UID и username приходят через env vars из plist (выставляются установщиком).

guard let ownerUIDStr = ProcessInfo.processInfo.environment["AWGROUTE_OWNER_UID"],
      let ownerUID = UInt32(ownerUIDStr),
      let ownerUser = ProcessInfo.processInfo.environment["AWGROUTE_OWNER_USER"],
      !ownerUser.isEmpty,
      // Защита от инъекции в hardcoded path-prefix: имя пользователя должно быть валидным
      // POSIX-логином без слэшей и спецсимволов. Иначе validateConfigPath обмануть тривиально.
      ownerUser.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." })
else {
    Logger.shared.error("missing or invalid AWGROUTE_OWNER_UID / AWGROUTE_OWNER_USER env")
    exit(1)
}

Logger.shared.info("starting awgroute-helper pid=\(getpid()) owner=\(ownerUser)(\(ownerUID))")

let backend = BackendManager(
    binary: "/Applications/AwgRoute.app/Contents/Resources/amnezia-box",
    pidFile: "/var/run/awgroute-helper-backend.pid",
    ownerUID: ownerUID,
    ownerUser: ownerUser
)

// При respawn'е helper'а launchd'ом во время работающего amnezia-box — подцепиться к процессу
// по PID-файлу, чтобы status() возвращал корректное состояние и мы могли его остановить.
backend.adoptExisting()

let dispatcher = CommandDispatcher(backend: backend, ownerUser: ownerUser)
let server = SocketServer(ownerUID: ownerUID, dispatcher: dispatcher)
server.run()
