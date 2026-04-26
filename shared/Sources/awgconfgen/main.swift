import Foundation
import AwgConfig

// Использование:
//   awgconfgen <file.conf>                            → полный JSON-конфиг amnezia-box на stdout
//   awgconfgen --endpoint-only <file.conf>            → только endpoint-объект
//   awgconfgen --rules <rules.json> <file.conf>       → полный конфиг с пользовательской route-секцией
//
// Удобно для:
//   swift run awgconfgen tests/conf-samples/example.conf > /tmp/cfg.json
//   backend/amnezia-box check -c /tmp/cfg.json

func usageAndExit() -> Never {
    FileHandle.standardError.write(Data("usage: awgconfgen [--endpoint-only] [--rules <rules.json>] <file.conf>\n".utf8))
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
var endpointOnly = false
var rulesPath: String? = nil
var nativeTun = false
if let i = args.firstIndex(of: "--endpoint-only") {
    endpointOnly = true
    args.remove(at: i)
}
if let i = args.firstIndex(of: "--rules") {
    args.remove(at: i)
    guard i < args.count else { usageAndExit() }
    rulesPath = args.remove(at: i)
}
if let i = args.firstIndex(of: "--native-tun") {
    nativeTun = true
    args.remove(at: i)
}
guard args.count == 1 else { usageAndExit() }

let path = args[0]
let text: String
do {
    text = try String(contentsOfFile: path, encoding: .utf8)
} catch {
    FileHandle.standardError.write(Data("read \(path): \(error)\n".utf8))
    exit(1)
}

do {
    let cfg = try AwgConfigParser.parse(text)
    for w in cfg.warnings {
        FileHandle.standardError.write(Data("warning: \(w)\n".utf8))
    }
    var userRoute: [String: Any]? = nil
    if let p = rulesPath {
        let rd = try Data(contentsOf: URL(fileURLWithPath: p))
        userRoute = try JSONSerialization.jsonObject(with: rd) as? [String: Any]
    }
    var opts = AwgJSONGenerator.Options()
    opts.useNativeTunMode = nativeTun
    let json = endpointOnly
        ? try AwgJSONGenerator.endpointJSON(from: cfg, options: opts)
        : try AwgJSONGenerator.fullConfigJSON(from: cfg, options: opts, userRoute: userRoute)
    FileHandle.standardOutput.write(json)
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("parse: \(error)\n".utf8))
    exit(1)
}
