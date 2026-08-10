import Foundation

/// URLSession-backed `VoiceTransport` against the relay (§5.2). mTLS rides
/// a session delegate: the Keychain identity answers the client-certificate
/// challenge, and the circle's private CA (when provided) replaces the
/// system trust store for the server side.
public final class RelayClient: NSObject, VoiceTransport, @unchecked Sendable {
    private let baseURL: URL
    private let identity: @Sendable () -> SecIdentity?
    private let anchors: @Sendable () -> [SecCertificate]
    /// Dev mode (CLIENT.md): assert identity as `X-Client-CN` on every
    /// request instead of a client certificate. Production servers strip
    /// the header; nil outside dev.
    private let devClientCN: String?
    private var session: URLSession!

    public init(baseURL: URL,
                identity: @escaping @Sendable () -> SecIdentity? = { nil },
                anchors: @escaping @Sendable () -> [SecCertificate] = { [] },
                devClientCN: String? = nil,
                configuration: URLSessionConfiguration = .default) {
        self.baseURL = baseURL
        self.identity = identity
        self.anchors = anchors
        self.devClientCN = devClientCN
        super.init()
        // An open transmission's download can legitimately go quiet for the
        // whole 60 s resume window while the sender reconnects; the default
        // 60 s inactivity timeout would sever it at exactly the wrong time.
        configuration.timeoutIntervalForRequest = 120
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    private func transmissionURL(_ txnId: String, suffix: String = "",
                                 query: [String: String] = [:]) -> URL {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("v1/transmissions/\(txnId)\(suffix)"),
            resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components.url!
    }

    private func request(_ url: URL, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let devClientCN {
            request.setValue(devClientCN, forHTTPHeaderField: "X-Client-CN")
        }
        return request
    }

    public func download(txnId: String, fromSeq: UInt32) -> AsyncThrowingStream<Data, Error> {
        let url = transmissionURL(txnId, suffix: "/stream",
                                  query: fromSeq > 0 ? ["from_seq": "\(fromSeq)"] : [:])
        let session = self.session!
        let request = self.request(url)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status != 410 else { throw VoiceTransportError.gone }
                    guard (200 ..< 300).contains(status) else {
                        throw VoiceTransportError.http(status)
                    }
                    // Re-chunk the byte stream: URLSession buffers internally,
                    // so this loop runs at network-chunk cadence, not per byte.
                    var buffer = Data()
                    for try await byte in bytes {
                        buffer.append(byte)
                        if buffer.count >= 4096 {
                            continuation.yield(buffer)
                            buffer = Data()
                        }
                    }
                    if !buffer.isEmpty { continuation.yield(buffer) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func upload(txnId: String, fromSeq: UInt32?, body: AsyncStream<Data>) async throws {
        var query: [String: String] = [:]
        if let fromSeq { query["from_seq"] = "\(fromSeq)" }
        var request = request(transmissionURL(txnId, query: query), method: "POST")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        var input: InputStream?
        var output: OutputStream?
        Stream.getBoundStreams(withBufferSize: 64 * 1024,
                               inputStream: &input, outputStream: &output)
        guard let input, let output else { throw VoiceTransportError.http(0) }
        request.httpBodyStream = input

        // Writer and request run concurrently: URLSession pulls from the
        // bound pair's input end while we push recorded frames into the
        // output end; closing the output is what ends the chunked body.
        let writer = Task.detached(priority: .userInitiated) {
            output.open()
            defer { output.close() }
            for await chunk in body {
                var remaining = chunk
                while !remaining.isEmpty {
                    while !output.hasSpaceAvailable {
                        if output.streamStatus == .closed || output.streamStatus == .error {
                            return
                        }
                        try? await Task.sleep(nanoseconds: 5_000_000)
                    }
                    let written = remaining.withUnsafeBytes { raw in
                        output.write(raw.bindMemory(to: UInt8.self).baseAddress!,
                                     maxLength: remaining.count)
                    }
                    guard written > 0 else { return }
                    remaining.removeFirst(written)
                }
            }
        }

        do {
            let (_, response) = try await session.data(for: request)
            writer.cancel()
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200 ..< 300).contains(status) else {
                throw VoiceTransportError.http(status)
            }
        } catch {
            writer.cancel()
            throw error
        }
    }

    public func status(txnId: String) async throws -> TransmissionStatus {
        let (data, response) = try await session.data(
            for: request(transmissionURL(txnId, suffix: "/status")))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status != 410 else { throw VoiceTransportError.gone }
        guard (200 ..< 300).contains(status) else { throw VoiceTransportError.http(status) }
        return try JSONDecoder().decode(TransmissionStatus.self, from: data)
    }

    public func catchup(afterIndex: Int64) async throws -> [CatchupRecord] {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("v1/transmissions"),
            resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "after_index", value: "\(afterIndex)")]
        let (data, response) = try await session.data(for: request(components.url!))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else { throw VoiceTransportError.http(status) }
        return try JSONDecoder().decode([CatchupRecord].self, from: data)
    }
}

extension RelayClient: URLSessionDelegate, URLSessionTaskDelegate {
    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           didReceive challenge: URLAuthenticationChallenge)
        async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        handle(challenge)
    }

    public func urlSession(_ session: URLSession,
                           didReceive challenge: URLAuthenticationChallenge)
        async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        handle(challenge)
    }

    private func handle(_ challenge: URLAuthenticationChallenge)
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodClientCertificate:
            guard let identity = identity() else { return (.performDefaultHandling, nil) }
            return (.useCredential,
                    URLCredential(identity: identity, certificates: nil, persistence: .forSession))
        case NSURLAuthenticationMethodServerTrust:
            let anchors = anchors()
            guard !anchors.isEmpty,
                  let trust = challenge.protectionSpace.serverTrust else {
                return (.performDefaultHandling, nil)
            }
            SecTrustSetAnchorCertificates(trust, anchors as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
            var error: CFError?
            if SecTrustEvaluateWithError(trust, &error) {
                return (.useCredential, URLCredential(trust: trust))
            }
            return (.cancelAuthenticationChallenge, nil)
        default:
            return (.performDefaultHandling, nil)
        }
    }
}
