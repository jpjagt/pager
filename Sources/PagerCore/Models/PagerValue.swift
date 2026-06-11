import Foundation

/// The DB node at /pagers/{pathId}. `updatedAt` is server-stamped
/// ({".sv":"timestamp"} in PUT bodies) and is debug-only — LWW keys on writtenAt.
public struct PagerValue: Equatable, Codable {
    public var ct: String
    public var writtenAt: Int64
    public var updatedBy: String
    public var updatedAt: Int64?

    public init(ct: String, writtenAt: Int64, updatedBy: String, updatedAt: Int64? = nil) {
        self.ct = ct
        self.writtenAt = writtenAt
        self.updatedBy = updatedBy
        self.updatedAt = updatedAt
    }
}

public enum LWW {
    /// Last-write-wins: newer writtenAt wins; ties break by updatedBy so all
    /// devices resolve identically. Strict — equal values do not "win".
    public static func wins(_ candidate: PagerValue, over current: PagerValue?) -> Bool {
        guard let current else { return true }
        if candidate.writtenAt != current.writtenAt {
            return candidate.writtenAt > current.writtenAt
        }
        return candidate.updatedBy > current.updatedBy
    }
}
