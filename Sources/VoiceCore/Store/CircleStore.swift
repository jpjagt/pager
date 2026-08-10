import Foundation
import Combine

/// A global-hotkey binding in Carbon terms (`RegisterEventHotKey` takes
/// exactly these two values). Stored per circle; every circle owns at most
/// one, and a combo is never double-bound.
public struct KeyBinding: Codable, Equatable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// ⌘⌥R — the default for the *first* circle only (kVK_ANSI_R with
    /// cmdKey|optionKey). Later circles start unbound: two circles must
    /// never share a shortcut, so there is nothing sensible to default to.
    public static let commandOptionR = KeyBinding(keyCode: 15, modifiers: 0x100 | 0x800)
}

/// One joined voice circle as this Mac knows it. `config` is what
/// provisioning returned; everything else is local-only state.
public struct VoiceCircle: Codable, Equatable, Identifiable {
    public var id: UUID
    public var config: CircleConfig
    /// Local-only, like pager nicknames — never synced.
    public var nickname: String
    public var shortcut: KeyBinding?
    /// Highest `tx_index` reconciled — the catch-up cursor (§5.2).
    public var lastTxIndex: Int64
    /// The circle CA's certificate chain (DER), from provisioning — the only
    /// trust anchors both TLS stacks accept. Not secret; the private key
    /// lives in the Keychain.
    public var caBundle: [Data]

    public init(id: UUID = UUID(), config: CircleConfig, nickname: String,
                shortcut: KeyBinding? = nil, lastTxIndex: Int64 = 0,
                caBundle: [Data] = []) {
        self.id = id
        self.config = config
        self.nickname = nickname
        self.shortcut = shortcut
        self.lastTxIndex = lastTxIndex
        self.caBundle = caBundle
    }
}

/// Source of truth for joined circles. Persists to UserDefaults as JSON —
/// the `LinkStore` idiom; the certificate/private key live in the Keychain,
/// never here.
public final class CircleStore: ObservableObject {
    private enum Keys {
        static let circles = "voice.circles"
        static let nicknameCounter = "voice.nicknameCounter"
    }

    @Published public private(set) var circles: [VoiceCircle]
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Keys.circles),
           let decoded = try? JSONDecoder().decode([VoiceCircle].self, from: data) {
            circles = decoded
        } else {
            circles = []
        }
    }

    @discardableResult
    public func add(config: CircleConfig, caBundle: [Data] = []) -> VoiceCircle {
        let counter = defaults.integer(forKey: Keys.nicknameCounter) + 1
        defaults.set(counter, forKey: Keys.nicknameCounter)
        let circle = VoiceCircle(
            config: config,
            nickname: "Locket \(counter)",
            shortcut: circles.isEmpty ? .commandOptionR : nil,
            caBundle: caBundle)
        circles.append(circle)
        save()
        return circle
    }

    public func remove(id: UUID) {
        circles.removeAll { $0.id == id }
        save()
    }

    public func update(_ circle: VoiceCircle) {
        guard let index = circles.firstIndex(where: { $0.id == circle.id }) else { return }
        circles[index] = circle
        save()
    }

    /// Binds `binding` to one circle, unbinding it anywhere else — a combo
    /// is moved, never shared. Returns the circle that lost it, so the UI
    /// can say so instead of failing silently.
    @discardableResult
    public func bind(_ binding: KeyBinding?, to id: UUID) -> VoiceCircle? {
        var displaced: VoiceCircle?
        if let binding {
            for index in circles.indices
            where circles[index].shortcut == binding && circles[index].id != id {
                circles[index].shortcut = nil
                displaced = circles[index]
            }
        }
        guard let index = circles.firstIndex(where: { $0.id == id }) else { return displaced }
        circles[index].shortcut = binding
        save()
        return displaced
    }

    /// Moves the catch-up cursor forward; never backward (out-of-order
    /// reconciliation must not rewind what we've already seen).
    public func advanceTxIndex(id: UUID, to txIndex: Int64) {
        guard let index = circles.firstIndex(where: { $0.id == id }),
              circles[index].lastTxIndex < txIndex else { return }
        circles[index].lastTxIndex = txIndex
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(circles) {
            defaults.set(data, forKey: Keys.circles)
        }
    }
}
