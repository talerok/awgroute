import Foundation
import AwgConfig

// Использование:
//   awgconfgen <file.conf>                 → полный JSON-конфиг amnezia-box на stdout
//   awgconfgen --endpoint-only <file.conf> → только endpoint-объект
//
// Удобно для:
//   swift run awgconfgen tests/conf-samples/example.conf > /tmp/cfg.json
//   backend/amnezia-box check -c /tmp/cfg.json

func usageAndExit() -> Never {
    FileHandle.standardError.write(Data("usage: awgconfgen [--endpoint-only] <file.conf>\n".utf8))
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
var endpointOnly = false
if let i = args.firstIndex(of: "--endpoint-only") {
    endpointOnly = true
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
    let json = endpointOnly
        ? try AwgJSONGenerator.endpointJSON(from: cfg)
        : try AwgJSONGenerator.fullConfigJSON(from: cfg)
    FileHandle.standardOutput.write(json)
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("parse: \(error)\n".utf8))
    exit(1)
}
