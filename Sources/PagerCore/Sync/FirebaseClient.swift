import Foundation

public enum FirebaseError: Error {
    case badStatus(Int)
}

public final class FirebaseClient: SyncTransport, @unchecked Sendable {
    private let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func nodeURL(pathId: String) -> URL {
        baseURL.appendingPathComponent("pagers/\(pathId).json")
    }

    public func get(pathId: String) async throws -> PagerValue? {
        let (data, response) = try await session.data(from: nodeURL(pathId: pathId))
        try Self.checkStatus(response)
        if data == Data("null".utf8) { return nil }
        return try JSONDecoder().decode(PagerValue.self, from: data)
    }

    public func put(pathId: String, value: PagerValue) async throws {
        var request = URLRequest(url: nodeURL(pathId: pathId))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.putBody(for: value)
        let (_, response) = try await session.data(for: request)
        try Self.checkStatus(response)
    }

    /// JSONSerialization (not Codable) so {".sv":"timestamp"} can be injected:
    /// the server replaces it with its own clock on write.
    static func putBody(for value: PagerValue) throws -> Data {
        var object: [String: Any] = [
            "ct": value.ct,
            "writtenAt": value.writtenAt,
            "updatedBy": value.updatedBy,
            "updatedAt": [".sv": "timestamp"],
        ]
        if let type = value.type { object["type"] = type }
        return try JSONSerialization.data(withJSONObject: object)
    }

    public func stream(pathId: String) -> AsyncThrowingStream<SSEEvent, Error> {
        let url = nodeURL(pathId: pathId)
        let session = self.session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: url)
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.timeoutInterval = 600 // idle timeout; keep-alives arrive every ~30s
                    let (bytes, response) = try await session.bytes(for: request)
                    try Self.checkStatus(response)
                    let parser = SSEParser()
                    var chunk = Data()
                    for try await byte in bytes {
                        chunk.append(byte)
                        if byte == UInt8(ascii: "\n") {
                            for event in parser.feed(chunk) { continuation.yield(event) }
                            chunk.removeAll(keepingCapacity: true)
                        }
                    }
                    continuation.finish() // server closed the stream
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func checkStatus(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw FirebaseError.badStatus(http.statusCode)
        }
    }
}
