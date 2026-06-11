import Foundation

public struct SSEEvent: Equatable {
    public let name: String
    public let data: String

    public init(name: String, data: String) {
        self.name = name
        self.data = data
    }
}

/// Incremental Server-Sent-Events parser. Feed raw bytes as they arrive;
/// buffers internally (as Data, so UTF-8 split across chunks is safe) and
/// emits complete events (blocks terminated by a blank line).
public final class SSEParser {
    private var buffer = Data()
    private static let separator = Data("\n\n".utf8)

    public init() {}

    public func feed(_ chunk: Data) -> [SSEEvent] {
        buffer.append(chunk)
        var events: [SSEEvent] = []
        while let range = buffer.range(of: Self.separator) {
            let block = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            if let event = Self.parseBlock(String(decoding: block, as: UTF8.self)) {
                events.append(event)
            }
        }
        return events
    }

    private static func parseBlock(_ block: String) -> SSEEvent? {
        var name: String?
        var dataLines: [String] = []
        for line in block.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("event:") {
                name = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            }
            // lines starting with ":" are comments; ignore
        }
        guard let name else { return nil }
        return SSEEvent(name: name, data: dataLines.joined(separator: "\n"))
    }
}
