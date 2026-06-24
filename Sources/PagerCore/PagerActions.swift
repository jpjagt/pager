import Foundation

public enum PagerActionError: Error, Equatable {
    case invalidCode
    case alreadyLinked
    case nodeNotFound
    case network
}

/// The create/join/send flows, extracted from the SwiftUI views so they can be
/// driven (and tested) without any UI. Talks to `SyncTransport` + `LinkStore`;
/// the views become thin shells that call these and map errors to messages.
@MainActor
public final class PagerActions {
    private let transport: SyncTransport
    private let store: LinkStore
    private let now: () -> Int64

    public nonisolated init(transport: SyncTransport, store: LinkStore,
                            now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.transport = transport
        self.store = store
        self.now = now
    }

    /// Creates a pager: writes an initial empty node (so joiners can verify the
    /// code exists), then persists the link. Returns the new link.
    @discardableResult
    public func createPager(code: ShareCode = ShareCode.generate()) async throws -> PagerLink {
        let crypto = PagerCrypto(code: code)
        let value = PagerValue(ct: try crypto.encrypt(""), writtenAt: now(), updatedBy: store.deviceId)
        do {
            try await transport.put(pathId: crypto.pathId, value: value)
        } catch {
            throw PagerActionError.network
        }
        return store.add(code: code)
    }

    public struct JoinResult {
        public let link: PagerLink
        /// The friend's existing message, if they'd already written one.
        public let friendMessage: String?
    }

    /// Joins an existing pager: validates the code, checks for an existing node,
    /// persists the link, and surfaces any message already waiting.
    @discardableResult
    public func joinPager(_ input: String) async throws -> JoinResult {
        guard let code = ShareCode.parse(input) else { throw PagerActionError.invalidCode }
        guard !store.links.contains(where: { $0.code == code.full }) else {
            throw PagerActionError.alreadyLinked
        }
        let crypto = PagerCrypto(code: code)
        let node: PagerValue?
        do {
            node = try await transport.get(pathId: crypto.pathId)
        } catch {
            throw PagerActionError.network
        }
        guard let node else { throw PagerActionError.nodeNotFound }
        let link = store.add(code: code)
        let text = crypto.decrypt(node.ct) ?? ""
        if !text.isEmpty {
            store.updateCachedText(id: link.id, text: text, writtenAt: node.writtenAt)
        }
        return JoinResult(link: link, friendMessage: text.isEmpty ? nil : text)
    }

    /// Encrypts and writes `text`, then caches it locally.
    public func send(text: String, code: ShareCode, linkId: UUID) async throws {
        let crypto = PagerCrypto(code: code)
        let value = PagerValue(ct: try crypto.encrypt(text), writtenAt: now(), updatedBy: store.deviceId)
        do {
            try await transport.put(pathId: crypto.pathId, value: value)
        } catch {
            throw PagerActionError.network
        }
        store.updateCachedText(id: linkId, text: text, writtenAt: value.writtenAt)
    }
}
