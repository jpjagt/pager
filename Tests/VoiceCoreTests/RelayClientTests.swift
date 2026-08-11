import XCTest
@testable import VoiceCore

/// URLProtocol stub (the `FirebaseClientTests` pattern): every request in a
/// test session lands in `handler`, which returns status, headers-free body
/// chunks, and captures the request for assertions.
final class VoiceStubURLProtocol: URLProtocol {
    struct Scripted {
        var status: Int
        var chunks: [Data]
    }

    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> Scripted)?
    nonisolated(unsafe) static var captured: [URLRequest] = []
    nonisolated(unsafe) static var capturedBodies: [Data] = []
    private static let lock = NSLock()

    static func reset() {
        lock.lock()
        handler = nil
        captured = []
        capturedBodies = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            var body = Data()
            if let stream = request.httpBodyStream {
                stream.open()
                var buffer = [UInt8](repeating: 0, count: 16 * 1024)
                while true {
                    let read = stream.read(&buffer, maxLength: buffer.count)
                    if read > 0 {
                        body.append(contentsOf: buffer[0 ..< read])
                    } else {
                        break
                    }
                }
                stream.close()
            }
            Self.lock.lock()
            Self.captured.append(request)
            Self.capturedBodies.append(body)
            let scripted = Self.handler?(request) ?? Scripted(status: 500, chunks: [])
            Self.lock.unlock()

            let response = HTTPURLResponse(url: request.url!, statusCode: scripted.status,
                                           httpVersion: "HTTP/1.1", headerFields: nil)!
            self.client?.urlProtocol(self, didReceive: response,
                                     cacheStoragePolicy: .notAllowed)
            for chunk in scripted.chunks {
                self.client?.urlProtocol(self, didLoad: chunk)
            }
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

final class RelayClientTests: XCTestCase {
    private var client: RelayClient!

    override func setUp() {
        super.setUp()
        VoiceStubURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VoiceStubURLProtocol.self]
        client = RelayClient(baseURL: URL(string: "https://relay.example")!,
                             configuration: configuration)
    }

    override func tearDown() {
        VoiceStubURLProtocol.reset()
        super.tearDown()
    }

    func testDownloadStreamsChunksInOrder() async throws {
        VoiceStubURLProtocol.handler = { _ in
            .init(status: 200, chunks: [Data([1, 2]), Data([3]), Data([4, 5, 6])])
        }
        var received = Data()
        for try await chunk in client.download(txnId: "t1", fromSeq: 0) {
            received.append(chunk)
        }
        XCTAssertEqual(received, Data([1, 2, 3, 4, 5, 6]))
        XCTAssertEqual(VoiceStubURLProtocol.captured.first?.url?.path,
                       "/v1/transmissions/t1/stream")
        XCTAssertNil(VoiceStubURLProtocol.captured.first?.url?.query)
    }

    func testDownloadFromSeqCarriesQuery() async throws {
        VoiceStubURLProtocol.handler = { _ in .init(status: 200, chunks: []) }
        for try await _ in client.download(txnId: "t1", fromSeq: 40) {}
        XCTAssertEqual(VoiceStubURLProtocol.captured.first?.url?.query, "from_seq=40")
    }

    func testDownloadGoneSurfacesAsGone() async {
        VoiceStubURLProtocol.handler = { _ in .init(status: 410, chunks: []) }
        do {
            for try await _ in client.download(txnId: "t1", fromSeq: 0) {}
            XCTFail("expected gone")
        } catch {
            XCTAssertEqual(error as? VoiceTransportError, .gone)
        }
    }

    func testUploadStreamsBodyAndResumeQuery() async throws {
        VoiceStubURLProtocol.handler = { _ in .init(status: 200, chunks: []) }
        let body = AsyncStream<Data> { continuation in
            continuation.yield(Data([0xAA, 0xBB]))
            continuation.yield(Data([0xCC]))
            continuation.finish()
        }
        try await client.upload(txnId: "t2", fromSeq: 7, body: body)
        XCTAssertEqual(VoiceStubURLProtocol.captured.first?.url?.query, "from_seq=7")
        XCTAssertEqual(VoiceStubURLProtocol.captured.first?.httpMethod, "POST")
        XCTAssertEqual(VoiceStubURLProtocol.capturedBodies.first, Data([0xAA, 0xBB, 0xCC]))
    }

    func testStatusParses() async throws {
        VoiceStubURLProtocol.handler = { _ in
            .init(status: 200,
                  chunks: [Data(#"{"state":"open","next_seq":141,"duration_ms":8460}"#.utf8)])
        }
        let status = try await client.status(txnId: "t3")
        XCTAssertEqual(status, TransmissionStatus(state: "open", nextSeq: 141,
                                                  durationMs: 8460))
        XCTAssertEqual(VoiceStubURLProtocol.captured.first?.url?.path,
                       "/v1/transmissions/t3/status")
    }

    func testCatchupAcceptsWrappedEnvelope() async throws {
        // The reference server wraps the array: {"transmissions": [...]}.
        let json = """
        {"transmissions": [{"txn_id":"a","sender":"vpd-1","circle":"cir-1",
          "tx_index":5,"state":"complete"}]}
        """
        VoiceStubURLProtocol.handler = { _ in .init(status: 200, chunks: [Data(json.utf8)]) }
        let records = try await client.catchup(afterIndex: 4)
        XCTAssertEqual(records.map(\.txnId), ["a"])
    }

    func testCatchupParsesRecordsAndCursor() async throws {
        let json = """
        [{"txn_id":"a","sender":"vpd-1","circle":"cir-1","tx_index":5,
          "frame_ms":60,"state":"complete","duration_ms":1000,"frame_count":17},
         {"txn_id":"b","sender":"vpd-2","circle":"cir-1","tx_index":6,"state":"open"}]
        """
        VoiceStubURLProtocol.handler = { _ in .init(status: 200, chunks: [Data(json.utf8)]) }
        let records = try await client.catchup(afterIndex: 4)
        XCTAssertEqual(VoiceStubURLProtocol.captured.first?.url?.query, "after_index=4")
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].frameCount, 17)
        XCTAssertEqual(records[1].state, "open")
    }

    func testDevModeSendsClientCNHeaderEverywhere() async throws {
        VoiceStubURLProtocol.handler = { _ in
            .init(status: 200, chunks: [Data(#"{"state":"open","next_seq":0}"#.utf8)])
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VoiceStubURLProtocol.self]
        let dev = RelayClient(baseURL: URL(string: "http://localhost:8080")!,
                              devClientCN: "vpd-devaa11",
                              configuration: configuration)
        _ = try await dev.status(txnId: "t")
        for try await _ in dev.download(txnId: "t2", fromSeq: 0) { break }
        let headers = VoiceStubURLProtocol.captured.map {
            $0.value(forHTTPHeaderField: "X-Client-CN")
        }
        XCTAssertEqual(headers, ["vpd-devaa11", "vpd-devaa11"])
        // And the production client sends none.
        VoiceStubURLProtocol.reset()
        VoiceStubURLProtocol.handler = { _ in
            .init(status: 200, chunks: [Data(#"{"state":"open","next_seq":0}"#.utf8)])
        }
        _ = try await client.status(txnId: "t3")
        XCTAssertNil(VoiceStubURLProtocol.captured.first?
            .value(forHTTPHeaderField: "X-Client-CN"))
    }

    func testHTTPErrorSurfaces() async {
        VoiceStubURLProtocol.handler = { _ in .init(status: 503, chunks: []) }
        do {
            _ = try await client.status(txnId: "t")
            XCTFail("expected http error")
        } catch {
            XCTAssertEqual(error as? VoiceTransportError, .http(503))
        }
    }
}
