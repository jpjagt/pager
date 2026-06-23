import Foundation
import PagerCore

// Decrypts the `ct` field of each line in a Pager sync log (JSONL), using one
// or more share codes. Lines whose ct doesn't decrypt under any given code are
// annotated `[other link]`; lines without a ct pass through unchanged.
//
//   swift run decode-log --code 5NDQ-WHM1-85X3-FWPQ ~/Library/Logs/Pager/pager-logs.jsonl

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

var cryptos: [PagerCrypto] = []
var path: String?

var args = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < args.count {
    switch args[i] {
    case "--code":
        guard i + 1 < args.count else { fail("--code needs a value") }
        guard let code = ShareCode.parse(args[i + 1]) else { fail("invalid share code: \(args[i + 1])") }
        cryptos.append(PagerCrypto(code: code))
        i += 2
    case "-h", "--help":
        print("usage: decode-log --code <SHARE-CODE> [--code …] <path-to-pager-logs.jsonl>")
        exit(0)
    default:
        path = args[i]
        i += 1
    }
}

guard let path else { fail("usage: decode-log --code <SHARE-CODE> [--code …] <path-to-pager-logs.jsonl>") }
guard cryptos.isEmpty == false else { fail("at least one --code is required to decrypt") }
guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { fail("cannot read \(path)") }

let decoder = JSONDecoder()
for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
    let raw = String(line)
    guard let data = raw.data(using: .utf8),
          let event = try? decoder.decode(SyncLogEvent.self, from: data),
          let ct = event.ct else {
        print(raw)
        continue
    }
    if let text = cryptos.lazy.compactMap({ $0.decrypt(ct) }).first {
        let encoded = (try? JSONEncoder().encode(text)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\(text)\""
        print("\(raw)  text:\(encoded)")
    } else {
        print("\(raw)  [other link]")
    }
}
