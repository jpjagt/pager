import Foundation

public protocol SyncTransport: Sendable {
    /// nil when the node does not exist.
    func get(pathId: String) async throws -> PagerValue?
    func put(pathId: String, value: PagerValue) async throws
    /// Long-lived SSE stream; finishes/throws when the connection drops.
    func stream(pathId: String) -> AsyncThrowingStream<SSEEvent, Error>
}
