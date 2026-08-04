# Drop-on & Image Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A pager can hold an E2E-encrypted image (dropped on the menu bar item or pasted in the popover) instead of text, shown as a bordered thumbnail in the menu bar and full-size in the popover; text containing an image URL gets a lazy popover preview.

**Architecture:** The wire node gains an optional `type` field (`"img"`; absent ⇒ `"text"`), and `ct` carries either encrypted UTF-8 text or encrypted JPEG bytes. The node is decrypted once at the sync boundary into a `PagerContent` enum (`.text`/`.image`) that flows through `SyncEngine` → `LinkStore` → `EditorSession` → UI. Images are re-encoded (≤ 1024 px long edge, JPEG ≤ 600 KB) before encryption, so they fit in the existing Firebase RTDB node — no second backend. LWW, echo suppression, and whole-node PUTs are untouched.

**Tech Stack:** Swift 5.9 / SwiftPM, macOS 13+, AppKit + SwiftUI shell, PagerCore uses only Foundation/CryptoKit/ImageIO/CoreGraphics/UniformTypeIdentifiers (ImageIO is not AppKit — core stays headless-testable). Zero third-party dependencies.

**Spec:** approved inline in the 2026-08-04 brainstorming session (no spec file — this plan is the reference). Design summary lives in the task descriptions below.

## Global Constraints

- macOS 13+ (Ventura), zero third-party dependencies (`Package.swift` gains nothing).
- No AppKit in new PagerCore code (existing `TextUtil.swift` is the lone legacy exception — don't add more).
- Wire `type` values are exactly `"img"` and `"text"`; **text writes omit `type` entirely** (back-compat: old clients and old rules accept them).
- Image processing constants: long edges `[1024, 768, 512]`, JPEG qualities `[0.8, 0.6, 0.4, 0.25]`, max encoded size `600_000` bytes.
- Text cap stays 500 chars (`EditorSession.maxLength`).
- Sync log lines must never contain image ciphertext — img events log `ct_len` (Int) instead of `ct`.
- `swift test` must stay fully offline/deterministic. `swift run e2e` covers the network path and is run once at the end (after the Firebase rules update is applied manually).
- Every task ends with `swift build && swift test` green and a commit.

## File Structure

```
Sources/PagerCore/
  Models/PagerContent.swift          # NEW — the decrypted content enum
  Models/PagerValue.swift            # + optional `type` field
  Models/PagerLink.swift             # + cachedIsImage (custom Codable init)
  Models/LinkStore.swift             # + updateCachedContent/cachedContent, owns ImageDiskCache
  Models/ImageDiskCache.swift        # NEW — decrypted image bytes on disk
  Models/EditorSession.swift         # draft becomes PagerContent; ContentCommitter protocol
  Crypto/PagerCrypto.swift           # + encryptData/decryptData + encryptContent/decryptContent
  Images/ImageCodec.swift            # NEW — decode/downscale/JPEG-encode (ImageIO)
  Images/ImageDisplayMath.swift      # NEW — 9:16 aspect-clamped display box math
  Images/ImageURLPreviewLoader.swift # NEW — mode-4 lazy remote preview
  Images/DropPayloadClassifier.swift # NEW — drop/paste contents → image|text decision
  Sync/SyncEngine.swift              # onText→onContent, commitContent, ct_len logging
  Sync/SyncLog.swift                 # SyncLogEvent + ctLen field
  Sync/FirebaseClient.swift          # putBody includes `type` when present
  PagerActions.swift                 # joinPager handles image nodes
Sources/Pager/
  App/StatusItemController.swift     # render(content:), bordered thumbnail
  App/StatusItemDropView.swift       # NEW — drag destination overlay on the button
  App/AppDelegate.swift              # onContent wiring, handleDrop, reconcile passes content
  UI/LinkViewModel.swift             # draftImage, pasteImage, clearImage, openDraftImage, preview loader
  UI/PagerImageView.swift            # NEW — clickable clamped image box w/ hover
  UI/PopoverView.swift               # image display, paste command, error caption
Sources/E2E/main.swift               # onContent adaptation + image round-trip scenario
Sources/E2E/Flows.swift              # onContent adaptation
Tests/PagerCoreTests/
  TestImageFactory.swift             # NEW — deterministic programmatic PNG fixtures
  ImageCodecTests.swift              # NEW
  PagerContentCryptoTests.swift      # NEW
  ImageDisplayMathTests.swift        # NEW
  ImageURLPreviewLoaderTests.swift   # NEW
  DropPayloadClassifierTests.swift   # NEW
  (existing test files updated in place)
firebase/rules.json                  # type + conditional ct cap
docs/firebase-setup.md               # note: re-apply rules
CLAUDE.md (AGENTS.md)                # architecture notes
```

---

### Task 1: `PagerContent`, `PagerValue.type`, data crypto, PUT body

**Files:**
- Create: `Sources/PagerCore/Models/PagerContent.swift`
- Modify: `Sources/PagerCore/Models/PagerValue.swift`
- Modify: `Sources/PagerCore/Crypto/PagerCrypto.swift`
- Modify: `Sources/PagerCore/Sync/FirebaseClient.swift` (putBody)
- Test: `Tests/PagerCoreTests/PagerContentCryptoTests.swift` (new), `Tests/PagerCoreTests/FirebaseClientTests.swift` (extend)

**Interfaces:**
- Produces: `PagerContent` (`.text(String)`/`.image(Data)`, `wireType: String?`, `isImage: Bool`, `textValue: String`, `imageData: Data?`, `sizeForLog: Int`, `PagerContent.imageWireType == "img"`); `PagerValue.type: String?` (last init param, default `nil`); `PagerCrypto.encryptData(_: Data) throws -> String` and `decryptData(_: String) -> Data?`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/PagerCoreTests/PagerContentCryptoTests.swift`:

```swift
import XCTest
@testable import PagerCore

final class PagerContentCryptoTests: XCTestCase {
    let crypto = PagerCrypto(code: ShareCode.generate())

    func testDataRoundTrip() throws {
        let bytes = Data((0..<4096).map { UInt8($0 % 251) })
        let ct = try crypto.encryptData(bytes)
        XCTAssertEqual(crypto.decryptData(ct), bytes)
    }

    func testDecryptDataRejectsTampering() throws {
        let ct = try crypto.encryptData(Data([1, 2, 3]))
        var raw = Data(base64Encoded: ct)!
        raw[raw.count - 1] ^= 0xFF
        XCTAssertNil(crypto.decryptData(raw.base64EncodedString()))
    }

    func testPagerValueDecodesWithoutType() throws {
        let json = #"{"ct":"abc","writtenAt":5,"updatedBy":"dev"}"#
        let value = try JSONDecoder().decode(PagerValue.self, from: Data(json.utf8))
        XCTAssertNil(value.type)
    }

    func testPagerValueDecodesWithType() throws {
        let json = #"{"ct":"abc","writtenAt":5,"updatedBy":"dev","type":"img"}"#
        let value = try JSONDecoder().decode(PagerValue.self, from: Data(json.utf8))
        XCTAssertEqual(value.type, "img")
    }

    func testContentAccessors() {
        XCTAssertEqual(PagerContent.text("hi").textValue, "hi")
        XCTAssertEqual(PagerContent.image(Data([1])).textValue, "")
        XCTAssertNil(PagerContent.text("hi").wireType)
        XCTAssertEqual(PagerContent.image(Data([1])).wireType, "img")
        XCTAssertEqual(PagerContent.image(Data([1, 2])).imageData, Data([1, 2]))
        XCTAssertNil(PagerContent.text("hi").imageData)
        XCTAssertTrue(PagerContent.image(Data()).isImage)
        XCTAssertEqual(PagerContent.text("abc").sizeForLog, 3)
        XCTAssertEqual(PagerContent.image(Data([1, 2, 3, 4])).sizeForLog, 4)
    }
}
```

Add to `Tests/PagerCoreTests/FirebaseClientTests.swift` (alongside the existing putBody test if one exists; otherwise as new methods in the existing class):

```swift
    func testPutBodyOmitsTypeForText() throws {
        let value = PagerValue(ct: "abc", writtenAt: 1, updatedBy: "dev")
        let body = try FirebaseClient.putBody(for: value)
        let object = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        XCTAssertNil(object["type"])
    }

    func testPutBodyIncludesTypeForImage() throws {
        let value = PagerValue(ct: "abc", writtenAt: 1, updatedBy: "dev", type: "img")
        let body = try FirebaseClient.putBody(for: value)
        let object = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        XCTAssertEqual(object["type"] as? String, "img")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PagerContentCryptoTests`
Expected: compile FAILURE (`PagerContent` not defined, `encryptData` missing, `type` missing).

- [ ] **Step 3: Implement**

Create `Sources/PagerCore/Models/PagerContent.swift`:

```swift
import Foundation

/// The decrypted value a pager holds: text or an image (already-processed JPEG
/// bytes). Parsed exactly once at the sync boundary; everything downstream
/// switches on this enum instead of probing wire fields.
public enum PagerContent: Equatable {
    case text(String)
    case image(Data)

    /// Wire value for `PagerValue.type`. Text writes omit the field entirely
    /// (absent ⇒ text) so old clients and old rules accept them unchanged.
    public static let imageWireType = "img"

    public var wireType: String? {
        if case .image = self { return Self.imageWireType }
        return nil
    }

    public var isImage: Bool {
        if case .image = self { return true }
        return false
    }

    /// The text, or "" for an image (what a text-only consumer should show).
    public var textValue: String {
        if case .text(let text) = self { return text }
        return ""
    }

    public var imageData: Data? {
        if case .image(let data) = self { return data }
        return nil
    }

    /// Plaintext size for log lines: chars for text, bytes for an image.
    public var sizeForLog: Int {
        switch self {
        case .text(let text): return text.count
        case .image(let data): return data.count
        }
    }
}
```

In `Sources/PagerCore/Models/PagerValue.swift`, add the field (keep it last in the init so existing positional call sites compile):

```swift
public struct PagerValue: Equatable, Codable {
    public var ct: String
    public var writtenAt: Int64
    public var updatedBy: String
    public var updatedAt: Int64?
    /// "img" for image nodes; nil/absent ⇒ text (back-compat).
    public var type: String?

    public init(ct: String, writtenAt: Int64, updatedBy: String, updatedAt: Int64? = nil,
                type: String? = nil) {
        self.ct = ct
        self.writtenAt = writtenAt
        self.updatedBy = updatedBy
        self.updatedAt = updatedAt
        self.type = type
    }
}
```

In `Sources/PagerCore/Crypto/PagerCrypto.swift`, add below the existing `decrypt`:

```swift
    /// Returns base64(nonce ‖ ciphertext ‖ tag) of raw bytes (image payloads).
    public func encryptData(_ data: Data) throws -> String {
        let sealed = try AES.GCM.seal(data, using: key)
        return sealed.combined!.base64EncodedString()
    }

    /// nil on any corruption/tampering/wrong key — caller keeps last good content.
    public func decryptData(_ ct: String) -> Data? {
        guard let data = Data(base64Encoded: ct),
              let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: key)
        else { return nil }
        return plain
    }
```

In `Sources/PagerCore/Sync/FirebaseClient.swift`, `putBody(for:)` becomes:

```swift
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
```

- [ ] **Step 4: Run the full suite**

Run: `swift test`
Expected: PASS (all existing tests still green — the new field is optional everywhere).

- [ ] **Step 5: Commit**

```bash
git add Sources/PagerCore Tests/PagerCoreTests
git commit -m "feat: PagerContent enum, optional PagerValue.type, raw-data crypto"
```

---

### Task 2: `ImageCodec` — decode, downscale, JPEG-encode

**Files:**
- Create: `Sources/PagerCore/Images/ImageCodec.swift`
- Create: `Tests/PagerCoreTests/TestImageFactory.swift`
- Test: `Tests/PagerCoreTests/ImageCodecTests.swift`

**Interfaces:**
- Produces: `ImageCodec.process(_: Data) throws -> Data` (JPEG ≤ 600 KB, long edge ≤ 1024), `ImageCodec.isDecodableImage(_: Data) -> Bool`, `ImageCodec.pixelSize(of: Data) -> CGSize?`, `ImageCodec.maxEncodedBytes = 600_000`, `ImageCodecError.notAnImage/.cannotEncode`.
- Consumes: nothing from earlier tasks.

- [ ] **Step 1: Write the fixture factory** (test-support, no production code)

Create `Tests/PagerCoreTests/TestImageFactory.swift`:

```swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Deterministic programmatic fixtures — no binary files in the repo, no
/// randomness (identical bytes on every run).
enum TestImageFactory {
    /// Opaque striped PNG of the given pixel size.
    static func png(width: Int, height: Int) -> Data {
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for x in stride(from: 0, to: width, by: 16) {
            let shade = CGFloat(x % 256) / 255
            ctx.setFillColor(CGColor(red: shade, green: 1 - shade, blue: 0.5, alpha: 1))
            ctx.fill(CGRect(x: x, y: 0, width: 16, height: height))
        }
        let image = ctx.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(
            out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }
}
```

- [ ] **Step 2: Write the failing tests**

Create `Tests/PagerCoreTests/ImageCodecTests.swift`:

```swift
import XCTest
@testable import PagerCore

final class ImageCodecTests: XCTestCase {
    func testProcessDownscalesLargeImage() throws {
        let jpeg = try ImageCodec.process(TestImageFactory.png(width: 3000, height: 2000))
        let size = try XCTUnwrap(ImageCodec.pixelSize(of: jpeg))
        XCTAssertLessThanOrEqual(max(size.width, size.height), 1024)
        XCTAssertLessThanOrEqual(jpeg.count, ImageCodec.maxEncodedBytes)
    }

    func testProcessKeepsSmallImageDimensions() throws {
        let jpeg = try ImageCodec.process(TestImageFactory.png(width: 200, height: 100))
        let size = try XCTUnwrap(ImageCodec.pixelSize(of: jpeg))
        // Thumbnailing must not upscale a small image.
        XCTAssertLessThanOrEqual(max(size.width, size.height), 200)
    }

    func testProcessOutputIsDecodableImage() throws {
        let jpeg = try ImageCodec.process(TestImageFactory.png(width: 640, height: 480))
        XCTAssertTrue(ImageCodec.isDecodableImage(jpeg))
    }

    func testProcessRejectsNonImageData() {
        XCTAssertThrowsError(try ImageCodec.process(Data("not an image".utf8))) { error in
            XCTAssertEqual(error as? ImageCodecError, .notAnImage)
        }
    }

    func testIsDecodableImage() {
        XCTAssertTrue(ImageCodec.isDecodableImage(TestImageFactory.png(width: 10, height: 10)))
        XCTAssertFalse(ImageCodec.isDecodableImage(Data("garbage".utf8)))
        XCTAssertFalse(ImageCodec.isDecodableImage(Data()))
    }

    func testPixelSize() {
        let size = ImageCodec.pixelSize(of: TestImageFactory.png(width: 123, height: 45))
        XCTAssertEqual(size, CGSize(width: 123, height: 45))
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter ImageCodecTests`
Expected: compile FAILURE (`ImageCodec` not defined).

- [ ] **Step 4: Implement**

Create `Sources/PagerCore/Images/ImageCodec.swift`:

```swift
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageCodecError: Error, Equatable {
    case notAnImage
    case cannotEncode
}

/// Re-encodes any readable image (PNG/JPEG/HEIC/GIF/TIFF…) to a JPEG small
/// enough to live E2E-encrypted inside the RTDB node. ImageIO only — no AppKit,
/// so this stays headless-testable in PagerCore.
public enum ImageCodec {
    public static let maxEncodedBytes = 600_000
    /// Long-edge caps, tried in order if the encoded size won't come down.
    static let longEdges: [CGFloat] = [1024, 768, 512]
    static let qualities: [CGFloat] = [0.8, 0.6, 0.4, 0.25]

    public static func isDecodableImage(_ data: Data) -> Bool {
        pixelSize(of: data) != nil
    }

    public static func pixelSize(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Double,
              let height = props[kCGImagePropertyPixelHeight] as? Double
        else { return nil }
        return CGSize(width: width, height: height)
    }

    /// Downscale to ≤ 1024 px long edge and JPEG-encode, stepping quality (then
    /// dimensions) down until the result fits maxEncodedBytes.
    public static func process(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { throw ImageCodecError.notAnImage }
        for edge in longEdges {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: edge,
                // Bake EXIF rotation into the pixels so receivers need no metadata.
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0, options as CFDictionary) else { throw ImageCodecError.notAnImage }
            for quality in qualities {
                let out = NSMutableData()
                guard let dest = CGImageDestinationCreateWithData(
                    out, UTType.jpeg.identifier as CFString, 1, nil) else {
                    throw ImageCodecError.cannotEncode
                }
                CGImageDestinationAddImage(
                    dest, image,
                    [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
                guard CGImageDestinationFinalize(dest) else { throw ImageCodecError.cannotEncode }
                if out.length <= maxEncodedBytes { return out as Data }
            }
        }
        throw ImageCodecError.cannotEncode
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter ImageCodecTests`
Expected: PASS (6 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/PagerCore/Images Tests/PagerCoreTests
git commit -m "feat: ImageCodec — downscale + JPEG-encode images to <=600KB via ImageIO"
```

---

### Task 3: Content envelope on `PagerCrypto`

**Files:**
- Modify: `Sources/PagerCore/Crypto/PagerCrypto.swift`
- Test: `Tests/PagerCoreTests/PagerContentCryptoTests.swift` (extend)

**Interfaces:**
- Consumes: `PagerContent` (Task 1), `ImageCodec.isDecodableImage` (Task 2).
- Produces: `PagerCrypto.encryptContent(_: PagerContent) throws -> (ct: String, type: String?)`, `PagerCrypto.decryptContent(ct: String, type: String?) -> PagerContent?`.

- [ ] **Step 1: Write the failing tests** (append to `PagerContentCryptoTests`)

```swift
    func testEncryptContentTextOmitsType() throws {
        let sealed = try crypto.encryptContent(.text("hello"))
        XCTAssertNil(sealed.type)
        XCTAssertEqual(crypto.decryptContent(ct: sealed.ct, type: sealed.type), .text("hello"))
    }

    func testEncryptContentImageRoundTrip() throws {
        let jpeg = try ImageCodec.process(TestImageFactory.png(width: 300, height: 200))
        let sealed = try crypto.encryptContent(.image(jpeg))
        XCTAssertEqual(sealed.type, "img")
        XCTAssertEqual(crypto.decryptContent(ct: sealed.ct, type: sealed.type), .image(jpeg))
    }

    func testDecryptContentAbsentTypeIsText() throws {
        let ct = try crypto.encrypt("legacy")
        XCTAssertEqual(crypto.decryptContent(ct: ct, type: nil), .text("legacy"))
    }

    func testDecryptContentRejectsImgThatIsNotAnImage() throws {
        // Valid ciphertext of bytes that do not decode as an image.
        let ct = try crypto.encryptData(Data("not a jpeg".utf8))
        XCTAssertNil(crypto.decryptContent(ct: ct, type: "img"))
    }

    func testDecryptContentRejectsTamperedImg() throws {
        let jpeg = try ImageCodec.process(TestImageFactory.png(width: 100, height: 100))
        let ct = try crypto.encryptData(jpeg)
        var raw = Data(base64Encoded: ct)!
        raw[raw.count - 1] ^= 0xFF
        XCTAssertNil(crypto.decryptContent(ct: raw.base64EncodedString(), type: "img"))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PagerContentCryptoTests`
Expected: compile FAILURE (`encryptContent` missing).

- [ ] **Step 3: Implement** (append to `PagerCrypto`)

```swift
    /// Seals content for the wire: (ciphertext, type-field value). Text omits
    /// the type field entirely (absent ⇒ text, back-compat).
    public func encryptContent(_ content: PagerContent) throws -> (ct: String, type: String?) {
        switch content {
        case .text(let text): return (try encrypt(text), nil)
        case .image(let data): return (try encryptData(data), PagerContent.imageWireType)
        }
    }

    /// The single decrypt-and-parse boundary. nil on corruption/tampering,
    /// non-UTF-8 text, or an img payload that is not a decodable image —
    /// caller keeps last good content.
    public func decryptContent(ct: String, type: String?) -> PagerContent? {
        if type == PagerContent.imageWireType {
            guard let data = decryptData(ct), ImageCodec.isDecodableImage(data) else { return nil }
            return .image(data)
        }
        guard let text = decrypt(ct) else { return nil }
        return .text(text)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter PagerContentCryptoTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/PagerCore/Crypto Tests/PagerCoreTests
git commit -m "feat: content envelope — encryptContent/decryptContent on PagerCrypto"
```

---

### Task 4: `ImageDiskCache` + cached content on `PagerLink`/`LinkStore`

**Files:**
- Create: `Sources/PagerCore/Models/ImageDiskCache.swift`
- Modify: `Sources/PagerCore/Models/PagerLink.swift`
- Modify: `Sources/PagerCore/Models/LinkStore.swift`
- Test: `Tests/PagerCoreTests/LinkStoreTests.swift` (extend)

**Interfaces:**
- Consumes: `PagerContent` (Task 1).
- Produces: `ImageDiskCache(directory:)` with `write(_: Data, for: UUID)` / `read(for: UUID) -> Data?` / `remove(for: UUID)`; `PagerLink.cachedIsImage: Bool`; `LinkStore.init(defaults:imageCache:)`, `LinkStore.updateCachedContent(id: UUID, content: PagerContent, writtenAt: Int64)`, `LinkStore.cachedContent(id: UUID) -> PagerContent`. `updateCachedText` becomes a wrapper over `updateCachedContent(.text(...))`.

- [ ] **Step 1: Write the failing tests** (append to `LinkStoreTests`; follow the file's existing pattern for creating an isolated `UserDefaults` suite)

```swift
    func testCachedContentImageRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkstore-img-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LinkStore(defaults: makeIsolatedDefaults(), imageCache: ImageDiskCache(directory: dir))
        let link = store.add(code: ShareCode.generate())

        let bytes = Data([0xFF, 0xD8, 0xFF, 0x01, 0x02, 0x03])
        store.updateCachedContent(id: link.id, content: .image(bytes), writtenAt: 42)

        XCTAssertEqual(store.cachedContent(id: link.id), .image(bytes))
        XCTAssertEqual(store.links.first?.cachedText, "")
        XCTAssertEqual(store.links.first?.cachedIsImage, true)
        XCTAssertEqual(store.links.first?.cachedWrittenAt, 42)
    }

    func testTextUpdateClearsImageCache() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkstore-img-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = ImageDiskCache(directory: dir)
        let store = LinkStore(defaults: makeIsolatedDefaults(), imageCache: cache)
        let link = store.add(code: ShareCode.generate())

        store.updateCachedContent(id: link.id, content: .image(Data([1])), writtenAt: 1)
        store.updateCachedText(id: link.id, text: "back to text", writtenAt: 2)

        XCTAssertEqual(store.cachedContent(id: link.id), .text("back to text"))
        XCTAssertNil(cache.read(for: link.id))
        XCTAssertEqual(store.links.first?.cachedIsImage, false)
    }

    func testRemoveDeletesCachedImageFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkstore-img-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = ImageDiskCache(directory: dir)
        let store = LinkStore(defaults: makeIsolatedDefaults(), imageCache: cache)
        let link = store.add(code: ShareCode.generate())

        store.updateCachedContent(id: link.id, content: .image(Data([1])), writtenAt: 1)
        store.remove(id: link.id)
        XCTAssertNil(cache.read(for: link.id))
    }

    func testPagerLinkDecodesWithoutCachedIsImage() throws {
        // Links persisted before image support lack the key — must default false.
        let json = """
        {"id":"\(UUID().uuidString)","code":"ABCDEFGHJKMNPQRS","nickname":"n",
         "appearance":{"maxWidth":250,"fontSize":13,"opacity":1},
         "cachedText":"hi","cachedWrittenAt":7}
        """
        let link = try JSONDecoder().decode(PagerLink.self, from: Data(json.utf8))
        XCTAssertFalse(link.cachedIsImage)
    }
```

If `LinkStoreTests` has no `makeIsolatedDefaults()` helper, add one matching the file's existing setup idiom (an isolated `UserDefaults(suiteName:)` wiped before use):

```swift
    private func makeIsolatedDefaults() -> UserDefaults {
        let name = "linkstore-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter LinkStoreTests`
Expected: compile FAILURE (`ImageDiskCache`, `cachedIsImage`, `updateCachedContent` missing).

- [ ] **Step 3: Implement**

Create `Sources/PagerCore/Models/ImageDiskCache.swift`:

```swift
import Foundation

/// Decrypted image bytes cached on disk, one file per link (UserDefaults would
/// bloat with ~500 KB blobs). Same trust boundary as `cachedText`: plaintext at
/// rest is by design — encryption exists only at the network boundary.
public final class ImageDiskCache: @unchecked Sendable {
    private let directory: URL

    /// ~/Library/Application Support/Pager/images
    public static let defaultDirectory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Pager/images")

    public init(directory: URL = ImageDiskCache.defaultDirectory) {
        self.directory = directory
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).jpg")
    }

    public func write(_ data: Data, for id: UUID) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url(for: id), options: .atomic)
    }

    public func read(for id: UUID) -> Data? {
        try? Data(contentsOf: url(for: id))
    }

    public func remove(for id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }
}
```

In `Sources/PagerCore/Models/PagerLink.swift`, add `cachedIsImage` with a custom decoder (mirrors how `AppearancePrefs` back-fills `opacity`):

```swift
public struct PagerLink: Codable, Equatable, Identifiable {
    public let id: UUID
    /// Canonical 16-char share code (entropy + checksum). Never sent anywhere.
    public let code: String
    /// Local-only label, never synced.
    public var nickname: String
    public var appearance: AppearancePrefs
    public var cachedText: String
    public var cachedWrittenAt: Int64
    /// True when the cached content is an image (bytes live in ImageDiskCache;
    /// cachedText is "" in that case).
    public var cachedIsImage: Bool

    public var shareCode: ShareCode { ShareCode(entropy: String(code.prefix(14))) }

    enum CodingKeys: String, CodingKey {
        case id, code, nickname, appearance, cachedText, cachedWrittenAt, cachedIsImage
    }

    public init(id: UUID = UUID(), code: String, nickname: String,
                appearance: AppearancePrefs = AppearancePrefs(),
                cachedText: String = "", cachedWrittenAt: Int64 = 0,
                cachedIsImage: Bool = false) {
        self.id = id
        self.code = code
        self.nickname = nickname
        self.appearance = appearance
        self.cachedText = cachedText
        self.cachedWrittenAt = cachedWrittenAt
        self.cachedIsImage = cachedIsImage
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        code = try container.decode(String.self, forKey: .code)
        nickname = try container.decode(String.self, forKey: .nickname)
        appearance = try container.decode(AppearancePrefs.self, forKey: .appearance)
        cachedText = try container.decode(String.self, forKey: .cachedText)
        cachedWrittenAt = try container.decode(Int64.self, forKey: .cachedWrittenAt)
        // Absent in links saved before image support.
        cachedIsImage = try container.decodeIfPresent(Bool.self, forKey: .cachedIsImage) ?? false
    }
}
```

In `Sources/PagerCore/Models/LinkStore.swift`:

```swift
    private let imageCache: ImageDiskCache

    public init(defaults: UserDefaults = .standard,
                imageCache: ImageDiskCache = ImageDiskCache()) {
        self.defaults = defaults
        self.imageCache = imageCache
        // ... rest of the existing init body unchanged ...
    }
```

Replace `updateCachedText` and add the content pair (keep `updateCachedText`'s doc position; `remove(id:)` gains one line):

```swift
    /// Text convenience over updateCachedContent (existing call sites keep working).
    public func updateCachedText(id: UUID, text: String, writtenAt: Int64) {
        updateCachedContent(id: id, content: .text(text), writtenAt: writtenAt)
    }

    /// Single write path for cached content. Text clears any cached image;
    /// an image empties cachedText and writes the bytes to disk.
    public func updateCachedContent(id: UUID, content: PagerContent, writtenAt: Int64) {
        guard let index = links.firstIndex(where: { $0.id == id }) else { return }
        switch content {
        case .text(let text):
            links[index].cachedText = text
            links[index].cachedIsImage = false
            imageCache.remove(for: id)
        case .image(let data):
            links[index].cachedText = ""
            links[index].cachedIsImage = true
            imageCache.write(data, for: id)
        }
        links[index].cachedWrittenAt = writtenAt
        save()
    }

    /// The cached content for a link (menu bar truth). Falls back to text if
    /// the image file is missing (e.g. deleted by the OS).
    public func cachedContent(id: UUID) -> PagerContent {
        guard let link = links.first(where: { $0.id == id }) else { return .text("") }
        if link.cachedIsImage, let data = imageCache.read(for: id) { return .image(data) }
        return .text(link.cachedText)
    }

    public func remove(id: UUID) {
        links.removeAll { $0.id == id }
        imageCache.remove(for: id)
        save()
    }
```

Note: `LinkStore` currently stores `defaults` as `private let defaults: UserDefaults` — keep that; only the init signature grows.

- [ ] **Step 4: Run the full suite**

Run: `swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/PagerCore/Models Tests/PagerCoreTests
git commit -m "feat: cached content — ImageDiskCache + PagerLink.cachedIsImage + LinkStore content API"
```

---

### Task 5: `SyncEngine` content boundary (`onContent`, `commitContent`, `ct_len` logging)

**Files:**
- Modify: `Sources/PagerCore/Sync/SyncEngine.swift`
- Modify: `Sources/PagerCore/Sync/SyncLog.swift`
- Modify: `Sources/PagerCore/Models/EditorSession.swift` (protocol rename only)
- Modify: `Sources/Pager/UI/LinkViewModel.swift` (NoopCommitter only)
- Modify: `Sources/Pager/App/AppDelegate.swift` (onContent wiring)
- Modify: `Sources/E2E/main.swift`, `Sources/E2E/Flows.swift` (onContent adaptation)
- Test: `Tests/PagerCoreTests/SyncEngineTests.swift` (extend + adapt), `Tests/PagerCoreTests/SyncLogTests.swift` (adapt if it asserts exact fields)

**Interfaces:**
- Consumes: `PagerContent`, `PagerValue.type`, `encryptContent`/`decryptContent` (Tasks 1, 3), `LinkStore.updateCachedContent` (Task 4).
- Produces: `SyncEngine.onContent: ((PagerContent, Int64) -> Void)?` (replaces `onText`); `ContentCommitter` protocol with `commitContent(_ content: PagerContent)` (replaces `TextCommitter`); `SyncEngine.commitText(_:)` kept as a convenience that calls `commitContent(.text(...))`; `SyncLogEvent.ctLen: Int?` (JSON key `ct_len`).

- [ ] **Step 1: Write the failing tests** (append to `SyncEngineTests`, following its existing stub-transport pattern for feeding scripted SSE `put` events and capturing PUTs; reuse the file's existing helpers)

```swift
    // Image node arrives → delivered as .image content.
    func testImageNodeDeliveredAsContent() async throws {
        // Arrange an engine like the file's existing tests do, then feed an SSE
        // put whose data was built with crypto.encryptContent(.image(jpeg)):
        let jpeg = try ImageCodec.process(TestImageFactory.png(width: 100, height: 80))
        let sealed = try crypto.encryptContent(.image(jpeg))
        var received: PagerContent?
        engine.onContent = { content, _ in received = content }
        // feed put event for PagerValue(ct: sealed.ct, writtenAt: 100,
        //                               updatedBy: "other", type: sealed.type)
        // ... existing scripted-stream mechanics ...
        XCTAssertEqual(received, .image(jpeg))
    }

    // img ct that decrypts to garbage → ignored, no delivery.
    func testGarbageImageNodeIgnored() async throws {
        let ct = try crypto.encryptData(Data("not a jpeg".utf8))
        var received: PagerContent?
        engine.onContent = { content, _ in received = content }
        // feed put event for PagerValue(ct: ct, writtenAt: 100, updatedBy: "other", type: "img")
        XCTAssertNil(received)
    }

    // commitContent(.image) → PUT carries type "img"; log has ct_len, not ct.
    func testCommitImagePutsTypedValueAndLogsLengthOnly() async throws {
        let jpeg = try ImageCodec.process(TestImageFactory.png(width: 100, height: 80))
        engine.commitContent(.image(jpeg))
        // ... wait for the stub transport to capture the PUT (existing helper) ...
        XCTAssertEqual(capturedPut?.type, "img")
        let imgEvents = logEvents.filter { $0.ev == "edit.commit" }
        XCTAssertTrue(imgEvents.allSatisfy { $0.ct == nil && $0.ctLen != nil })
    }
```

Adapt these skeletons to the file's actual fixture names (`engine`, `crypto`, captured-PUT and log-capture helpers) — the file already has everything needed; only the closures and assertions are new. Also mechanically update every existing `engine.onText = { text, wa in ... }` closure in the file to `engine.onContent = { content, wa in ... }` using `content.textValue` where a `String` was asserted.

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SyncEngineTests`
Expected: compile FAILURE (`onContent`, `commitContent`, `ctLen` missing).

- [ ] **Step 3: Implement `SyncLogEvent.ctLen`**

In `Sources/PagerCore/Sync/SyncLog.swift`, add to `SyncLogEvent`: property `public var ctLen: Int?`, coding key `case ctLen = "ct_len"` in the existing `CodingKeys`, and an `ctLen: Int? = nil` parameter to the memberwise init (after `ct`), assigned in the body.

- [ ] **Step 4: Implement the engine changes**

In `Sources/PagerCore/Models/EditorSession.swift`, rename the protocol (the session's own generalization comes in Task 6 — here only keep it compiling):

```swift
/// The commit seam. `SyncEngine` is the real implementation; tests/e2e inject a
/// stub. Keeps `EditorSession` free of any network/engine internals.
@MainActor
public protocol ContentCommitter: AnyObject {
    func commitContent(_ content: PagerContent)
}
```

and in `EditorSession`: change `private let committer: TextCommitter` → `ContentCommitter`, the init parameter type likewise, and `commit()`'s call to `committer.commitContent(.text(text))`.

In `Sources/Pager/UI/LinkViewModel.swift`: `let committer: TextCommitter = engine ?? NoopCommitter()` → `let committer: ContentCommitter = engine ?? NoopCommitter()`, and:

```swift
/// Used when there is no engine: edits are held locally, commit goes nowhere.
@MainActor
private final class NoopCommitter: ContentCommitter {
    func commitContent(_ content: PagerContent) {}
}
```

In `Sources/PagerCore/Sync/SyncEngine.swift`:

1. Conformance: `public final class SyncEngine: ContentCommitter`.
2. Callback: replace `public var onText: ((String, Int64) -> Void)?` with

```swift
    public var onContent: ((PagerContent, Int64) -> Void)?
```

3. Add `ctLen: Int? = nil` to the private `event(...)` helper's parameters and pass it through to `SyncLogEvent(... ct: ct, ctLen: ctLen, ...)`.
4. Add the log-field helper:

```swift
    /// img ciphertext is ~800 KB — log its length, never its content (the 2 MB
    /// log cap would blow instantly, and decode-log doesn't need it).
    private static func ctFields(_ value: PagerValue) -> (ct: String?, ctLen: Int?) {
        value.type == PagerContent.imageWireType ? (nil, value.ct.count) : (value.ct, nil)
    }
```

5. Replace `commitText` with:

```swift
    /// Encrypts and flushes immediately, skipping the debounce — the single
    /// commit point (popover close / menu-bar drop).
    public func commitContent(_ content: PagerContent) {
        guard let sealed = try? crypto.encryptContent(content) else { return }
        let writtenAt = now()
        let value = PagerValue(ct: sealed.ct, writtenAt: writtenAt,
                               updatedBy: deviceId, type: sealed.type)
        pending = value
        let fields = Self.ctFields(value)
        event("edit.commit", writtenAt: writtenAt, len: content.sizeForLog,
              ct: fields.ct, ctLen: fields.ctLen)
        debounceTask?.cancel()
        debounceTask = nil
        scheduleFlush()
    }

    /// Text convenience (tests + e2e call sites).
    public func commitText(_ text: String) { commitContent(.text(text)) }
```

6. In `apply(remote:)`, replace the decrypt tail with:

```swift
        lastApplied = remote
        // Undecryptable (corrupt/tampered/not a decodable image): keep last good content.
        let fields = Self.ctFields(remote)
        if let content = crypto.decryptContent(ct: remote.ct, type: remote.type) {
            event("apply.accept", writtenAt: remote.writtenAt, len: content.sizeForLog,
                  ct: fields.ct, ctLen: fields.ctLen)
            onContent?(content, remote.writtenAt)
        } else {
            event("apply.undecryptable", writtenAt: remote.writtenAt,
                  ct: fields.ct, ctLen: fields.ctLen)
        }
```

7. In `flushPending`, the success log line becomes:

```swift
                let fields = Self.ctFields(value)
                event("flush.put_ok", writtenAt: value.writtenAt, ct: fields.ct, ctLen: fields.ctLen)
```

(`setText` is text-only and stays exactly as it is.)

- [ ] **Step 5: Update the call sites so the repo compiles**

- `Sources/Pager/App/AppDelegate.swift`, in `addController(for:)`:

```swift
        engine.onContent = { [weak self] content, writtenAt in
            self?.store.updateCachedContent(id: linkId, content: content, writtenAt: writtenAt)
        }
```

- `Sources/E2E/main.swift`: `a.onText = { t, _ in aView = t }` → `a.onContent = { c, _ in aView = c.textValue }` (same for `b`).
- `Sources/E2E/Flows.swift`, in `Device.connect()`: `engine.onText = { [weak self] text, _ in self?.received[id] = text }` → `engine.onContent = { [weak self] content, _ in self?.received[id] = content.textValue }`.

- [ ] **Step 6: Run the full suite and build all targets**

Run: `swift build && swift test`
Expected: PASS (including the three new SyncEngine tests). If `SyncLogTests` asserts an exhaustive field list, add `ctLen` there.

- [ ] **Step 7: Commit**

```bash
git add Sources Tests
git commit -m "feat: SyncEngine speaks PagerContent — onContent, commitContent, ct_len logging"
```

---

### Task 6: `EditorSession` content draft

**Files:**
- Modify: `Sources/PagerCore/Models/EditorSession.swift`
- Test: `Tests/PagerCoreTests/EditorSessionTests.swift` (extend + adapt)

**Interfaces:**
- Consumes: `ContentCommitter` (Task 5), `LinkStore.updateCachedContent`/`cachedContent` (Task 4), `ImageCodec` (Task 2).
- Produces: `EditorSession.content: PagerContent` (read-only), `text: String` (computed, `content.textValue`), `draftImageData: Data?`, `setImage(_ raw: Data) throws` (runs `ImageCodec.process`), `clearImage()`, `edit(_:)`/`commit()` as before but content-typed.

- [ ] **Step 1: Write the failing tests** (append to `EditorSessionTests`, reusing its stub committer/store fixtures; the stub committer now records `PagerContent`)

```swift
    func testSetImageCommitsImageContent() throws {
        let raw = TestImageFactory.png(width: 800, height: 600)
        try session.setImage(raw)
        XCTAssertNotNil(session.draftImageData)
        XCTAssertEqual(session.text, "")
        session.commit()
        guard case .image(let sent)? = committer.lastContent else {
            return XCTFail("expected image commit")
        }
        XCTAssertTrue(ImageCodec.isDecodableImage(sent))
        XCTAssertLessThanOrEqual(sent.count, ImageCodec.maxEncodedBytes)
        XCTAssertEqual(store.cachedContent(id: linkId), .image(sent))
    }

    func testSetImageRejectsGarbageAndKeepsDraft() {
        session.edit("my draft")
        XCTAssertThrowsError(try session.setImage(Data("junk".utf8)))
        XCTAssertEqual(session.text, "my draft") // draft untouched on failure
    }

    func testTypingReplacesImageDraft() throws {
        try session.setImage(TestImageFactory.png(width: 100, height: 100))
        session.edit("words now")
        XCTAssertNil(session.draftImageData)
        session.commit()
        XCTAssertEqual(committer.lastContent, .text("words now"))
    }

    func testClearImageResetsToEmptyText() throws {
        try session.setImage(TestImageFactory.png(width: 100, height: 100))
        session.clearImage()
        XCTAssertNil(session.draftImageData)
        session.commit()
        XCTAssertEqual(committer.lastContent, .text(""))
    }

    func testSessionOpensOnCachedImage() throws {
        let jpeg = try ImageCodec.process(TestImageFactory.png(width: 100, height: 100))
        store.updateCachedContent(id: linkId, content: .image(jpeg), writtenAt: 1)
        let fresh = EditorSession(linkId: linkId, store: store, committer: committer)
        XCTAssertEqual(fresh.draftImageData, jpeg)
    }
```

Adapt fixture names to the file's existing ones; change the stub committer from `commitText`-recording to:

```swift
@MainActor
final class StubCommitter: ContentCommitter {
    var lastContent: PagerContent?
    func commitContent(_ content: PagerContent) { lastContent = content }
}
```

and update existing assertions from `lastText == "x"` to `lastContent == .text("x")`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter EditorSessionTests`
Expected: compile FAILURE (`setImage`, `draftImageData`, `clearImage` missing).

- [ ] **Step 3: Implement** — `EditorSession` becomes:

```swift
/// The pure editing logic behind the popover, extracted from `LinkViewModel` so
/// it can be driven headlessly (unit tests + e2e). No AppKit.
///
/// Model: the draft is private and holds either text or an image (never both).
/// `edit`/`setImage` mutate only the draft. `commit` is the single point that
/// pushes (popover close, or immediately for a menu-bar drop). Remote values
/// land in the store/menu bar independently and never overwrite a live draft.
@MainActor
public final class EditorSession {
    public private(set) var content: PagerContent
    public private(set) var detectedURLs: [TextUtil.URLMatch]

    public static let maxLength = 500

    private let linkId: UUID
    private let store: LinkStore
    private let committer: ContentCommitter
    private let now: () -> Int64
    private var dirty = false

    public init(linkId: UUID, store: LinkStore, committer: ContentCommitter,
                now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.linkId = linkId
        self.store = store
        self.committer = committer
        self.now = now
        let cached = store.cachedContent(id: linkId)
        self.content = cached
        self.detectedURLs = TextUtil.detectURLs(in: cached.textValue)
    }

    /// The draft's text ("" while the draft is an image).
    public var text: String { content.textValue }

    /// The draft's image bytes (nil while the draft is text).
    public var draftImageData: Data? { content.imageData }

    /// The current shared/remote value (what the menu bar shows). Read-only here
    /// — the draft is never replaced from it while editing.
    public var currentRemoteText: String {
        store.links.first(where: { $0.id == linkId })?.cachedText ?? ""
    }

    /// Updates the private draft only: char cap, URL detection, mark dirty.
    /// Replaces an image draft (a pager holds text OR an image, never both).
    public func edit(_ newText: String) {
        let capped = newText.count > Self.maxLength ? String(newText.prefix(Self.maxLength)) : newText
        content = .text(capped)
        detectedURLs = TextUtil.detectURLs(in: capped)
        dirty = true
    }

    /// Replaces the draft with a processed image (downscaled, JPEG ≤ 600 KB).
    /// Throws ImageCodecError on unreadable data; the draft is untouched then.
    public func setImage(_ raw: Data) throws {
        let jpeg = try ImageCodec.process(raw)
        content = .image(jpeg)
        detectedURLs = []
        dirty = true
    }

    /// The ✕ affordance: back to an empty text draft.
    public func clearImage() {
        guard content.isImage else { return }
        content = .text("")
        detectedURLs = []
        dirty = true
    }

    /// The single commit point. Pushes the draft via the committer and writes it
    /// to the cache so the menu bar reflects the just-sent content (own writes
    /// are echo-suppressed, so onContent won't do it).
    public func commit() {
        guard dirty else { return }
        dirty = false
        committer.commitContent(content)
        store.updateCachedContent(id: linkId, content: content, writtenAt: now())
    }
}
```

- [ ] **Step 4: Run the full suite**

Run: `swift build && swift test`
Expected: PASS. (`LinkViewModel` still compiles: it reads `session.text` and calls `session.edit`/`commit`, all still present.)

- [ ] **Step 5: Commit**

```bash
git add Sources/PagerCore/Models Tests/PagerCoreTests
git commit -m "feat: EditorSession drafts PagerContent — setImage/clearImage, content commit"
```

---

### Task 7: `PagerActions.joinPager` handles image nodes

**Files:**
- Modify: `Sources/PagerCore/PagerActions.swift`
- Test: `Tests/PagerCoreTests/PagerActionsTests.swift` (extend)

**Interfaces:**
- Consumes: `decryptContent` (Task 3), `LinkStore.updateCachedContent` (Task 4).
- Produces: unchanged signatures; `JoinResult.friendMessage` stays `String?` and is `nil` for a waiting image (the menu bar thumbnail shows it immediately — no wording needed in `AddPagerView`).

- [ ] **Step 1: Write the failing test** (append to `PagerActionsTests`, reusing its stub-transport fixture that returns a canned node from `get`)

```swift
    func testJoinWithWaitingImageCachesItAndOmitsFriendMessage() async throws {
        let code = ShareCode.generate()
        let crypto = PagerCrypto(code: code)
        let jpeg = try ImageCodec.process(TestImageFactory.png(width: 200, height: 150))
        let sealed = try crypto.encryptContent(.image(jpeg))
        // Configure the stub transport's get() to return:
        // PagerValue(ct: sealed.ct, writtenAt: 9, updatedBy: "friend", type: sealed.type)
        // ... using the file's existing stub mechanics ...

        let result = try await actions.joinPager(code.display)
        XCTAssertNil(result.friendMessage)
        XCTAssertEqual(store.cachedContent(id: result.link.id), .image(jpeg))
        XCTAssertEqual(store.links.first?.cachedWrittenAt, 9)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PagerActionsTests`
Expected: FAIL — the image node's `ct` doesn't UTF-8-decode, so today's code caches nothing (`cachedContent` returns `.text("")`).

- [ ] **Step 3: Implement** — in `joinPager`, replace the tail after `guard let node`:

```swift
        let link = store.add(code: code)
        let content = crypto.decryptContent(ct: node.ct, type: node.type) ?? .text("")
        switch content {
        case .text(let text) where !text.isEmpty:
            store.updateCachedContent(id: link.id, content: content, writtenAt: node.writtenAt)
            return JoinResult(link: link, friendMessage: text)
        case .image:
            // Cache it so the menu bar thumbnail appears right away; no text to surface.
            store.updateCachedContent(id: link.id, content: content, writtenAt: node.writtenAt)
            return JoinResult(link: link, friendMessage: nil)
        default:
            return JoinResult(link: link, friendMessage: nil)
        }
```

Also update the `JoinResult.friendMessage` doc comment: `/// The friend's existing text message, if any. nil for an image — the menu bar thumbnail shows it.`

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter PagerActionsTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/PagerCore/PagerActions.swift Tests/PagerCoreTests
git commit -m "feat: joinPager caches a waiting image node"
```

---

### Task 8: `ImageDisplayMath` — aspect-clamped display boxes

**Files:**
- Create: `Sources/PagerCore/Images/ImageDisplayMath.swift`
- Test: `Tests/PagerCoreTests/ImageDisplayMathTests.swift`

**Interfaces:**
- Produces: `ImageDisplayMath.minAspect: Double` (= 9/16), `ImageDisplayMath.boxSize(imageSize: CGSize, maxWidth: Double, maxHeight: Double) -> CGSize`. Used by the popover image view AND the menu bar thumbnail composer.

- [ ] **Step 1: Write the failing tests**

Create `Tests/PagerCoreTests/ImageDisplayMathTests.swift`:

```swift
import XCTest
@testable import PagerCore

final class ImageDisplayMathTests: XCTestCase {
    func testWideImageFillsWidth() {
        let box = ImageDisplayMath.boxSize(
            imageSize: CGSize(width: 2000, height: 1000), maxWidth: 328, maxHeight: 240)
        XCTAssertEqual(box.width, 328, accuracy: 0.5)
        XCTAssertEqual(box.height, 164, accuracy: 0.5)
    }

    func testSquareImageCappedByHeight() {
        let box = ImageDisplayMath.boxSize(
            imageSize: CGSize(width: 500, height: 500), maxWidth: 328, maxHeight: 240)
        XCTAssertEqual(box.width, 240, accuracy: 0.5)
        XCTAssertEqual(box.height, 240, accuracy: 0.5)
    }

    func testVeryTallImageClampedToNineSixteen() {
        // 1:3 is taller than 9:16 → the BOX stays 9:16; the image letterboxes inside.
        let box = ImageDisplayMath.boxSize(
            imageSize: CGSize(width: 300, height: 900), maxWidth: 328, maxHeight: 240)
        XCTAssertEqual(box.width / box.height, 9.0 / 16.0, accuracy: 0.01)
        XCTAssertEqual(box.height, 240, accuracy: 0.5)
    }

    func testDegenerateInputsReturnZero() {
        XCTAssertEqual(ImageDisplayMath.boxSize(
            imageSize: .zero, maxWidth: 328, maxHeight: 240), .zero)
        XCTAssertEqual(ImageDisplayMath.boxSize(
            imageSize: CGSize(width: 10, height: 10), maxWidth: 0, maxHeight: 240), .zero)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ImageDisplayMathTests`
Expected: compile FAILURE.

- [ ] **Step 3: Implement**

Create `Sources/PagerCore/Images/ImageDisplayMath.swift`:

```swift
import Foundation

/// Pure display-box math shared by the popover image view and the menu bar
/// thumbnail: fit within max bounds, but never let the box get narrower than
/// 9:16 — taller images letterbox inside the clamped box.
public enum ImageDisplayMath {
    /// Narrowest allowed box aspect (width / height).
    public static let minAspect: Double = 9.0 / 16.0

    public static func boxSize(imageSize: CGSize, maxWidth: Double, maxHeight: Double) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0, maxWidth > 0, maxHeight > 0 else {
            return .zero
        }
        let aspect = max(imageSize.width / imageSize.height, minAspect)
        let height = min(maxHeight, maxWidth / aspect)
        return CGSize(width: height * aspect, height: height)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ImageDisplayMathTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/PagerCore/Images Tests/PagerCoreTests
git commit -m "feat: ImageDisplayMath — 9:16-clamped display box"
```

---

### Task 9: `DropPayloadClassifier`

**Files:**
- Create: `Sources/PagerCore/Images/DropPayloadClassifier.swift`
- Test: `Tests/PagerCoreTests/DropPayloadClassifierTests.swift`

**Interfaces:**
- Consumes: `ImageCodec.isDecodableImage` (Task 2), `EditorSession.maxLength` (Task 6).
- Produces: `DropPayload` (`.image(Data)`/`.text(String)`), `DropPayloadClassifier.classify(imageDatas: [Data], strings: [String]) -> DropPayload?`. The AppKit layer reads the pasteboard (direct image data + dropped-file contents + strings) and feeds it here.

- [ ] **Step 1: Write the failing tests**

Create `Tests/PagerCoreTests/DropPayloadClassifierTests.swift`:

```swift
import XCTest
@testable import PagerCore

final class DropPayloadClassifierTests: XCTestCase {
    let png = TestImageFactory.png(width: 50, height: 50)

    func testImageBeatsString() {
        let payload = DropPayloadClassifier.classify(imageDatas: [png], strings: ["hello"])
        XCTAssertEqual(payload, .image(png))
    }

    func testFirstDecodableImageWins() {
        let payload = DropPayloadClassifier.classify(
            imageDatas: [Data("junk".utf8), png], strings: [])
        XCTAssertEqual(payload, .image(png))
    }

    func testStringFallback() {
        let payload = DropPayloadClassifier.classify(
            imageDatas: [Data("junk".utf8)], strings: ["dropped text"])
        XCTAssertEqual(payload, .text("dropped text"))
    }

    func testBlankStringsSkipped() {
        let payload = DropPayloadClassifier.classify(imageDatas: [], strings: ["  \n", "real"])
        XCTAssertEqual(payload, .text("real"))
    }

    func testLongTextTruncatedToCap() {
        let long = String(repeating: "x", count: 900)
        let payload = DropPayloadClassifier.classify(imageDatas: [], strings: [long])
        XCTAssertEqual(payload, .text(String(repeating: "x", count: EditorSession.maxLength)))
    }

    func testNothingUsableReturnsNil() {
        XCTAssertNil(DropPayloadClassifier.classify(imageDatas: [Data("junk".utf8)], strings: ["   "]))
        XCTAssertNil(DropPayloadClassifier.classify(imageDatas: [], strings: []))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter DropPayloadClassifierTests`
Expected: compile FAILURE.

- [ ] **Step 3: Implement**

Create `Sources/PagerCore/Images/DropPayloadClassifier.swift`:

```swift
import Foundation

/// What a drop/paste resolved to. `.image` carries RAW bytes — the caller runs
/// ImageCodec.process (via EditorSession.setImage) before anything is stored.
public enum DropPayload: Equatable {
    case image(Data)
    case text(String)
}

/// Pure decision logic for drops and pastes: given everything readable off the
/// pasteboard, pick what the pager should hold. Image beats text; first
/// decodable image wins; text is capped at the editor's max length.
public enum DropPayloadClassifier {
    public static func classify(imageDatas: [Data], strings: [String]) -> DropPayload? {
        if let data = imageDatas.first(where: { ImageCodec.isDecodableImage($0) }) {
            return .image(data)
        }
        guard let text = strings.first(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else { return nil }
        return .text(String(text.prefix(EditorSession.maxLength)))
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter DropPayloadClassifierTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/PagerCore/Images Tests/PagerCoreTests
git commit -m "feat: DropPayloadClassifier — pure drop/paste image-vs-text decision"
```

---

### Task 10: `ImageURLPreviewLoader` (mode-4 remote previews)

**Files:**
- Create: `Sources/PagerCore/Images/ImageURLPreviewLoader.swift`
- Test: `Tests/PagerCoreTests/ImageURLPreviewLoaderTests.swift`

**Interfaces:**
- Consumes: `ImageCodec.isDecodableImage` (Task 2).
- Produces: `ImageURLPreviewLoader` (`@MainActor`, `ObservableObject`): `preview: Preview?` (`@Published`, `Preview == (url: URL, data: Data)` struct), `load(urls: [URL])`, injectable `Fetch = @Sendable (URL) async throws -> Data`, default `urlSessionFetch` (10 s timeout, 10 MB cap), session-lifetime in-memory cache (20 entries).

- [ ] **Step 1: Write the failing tests**

Create `Tests/PagerCoreTests/ImageURLPreviewLoaderTests.swift`:

```swift
import XCTest
@testable import PagerCore

@MainActor
final class ImageURLPreviewLoaderTests: XCTestCase {
    let png = TestImageFactory.png(width: 40, height: 40)
    let imgURL = URL(string: "https://example.com/cat.jpg")!
    let htmlURL = URL(string: "https://example.com/page")!

    private func waitForPreview(_ loader: ImageURLPreviewLoader,
                                timeout: TimeInterval = 2) async -> ImageURLPreviewLoader.Preview? {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if let preview = loader.preview { return preview }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return loader.preview
    }

    func testFirstImageURLWins() async {
        let loader = ImageURLPreviewLoader(fetch: { [png] url in
            url.lastPathComponent == "cat.jpg" ? png : Data("<html>".utf8)
        })
        loader.load(urls: [htmlURL, imgURL])
        let preview = await waitForPreview(loader)
        XCTAssertEqual(preview?.url, imgURL)
        XCTAssertEqual(preview?.data, png)
    }

    func testNoImageMeansNoPreview() async {
        let loader = ImageURLPreviewLoader(fetch: { _ in Data("<html>".utf8) })
        loader.load(urls: [htmlURL])
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(loader.preview)
    }

    func testFetchFailureIsSilent() async {
        let loader = ImageURLPreviewLoader(fetch: { _ in throw URLError(.timedOut) })
        loader.load(urls: [imgURL])
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(loader.preview)
    }

    func testNonHTTPURLsFiltered() async {
        var fetched: [URL] = []
        let loader = ImageURLPreviewLoader(fetch: { url in fetched.append(url); return Data() })
        loader.load(urls: [URL(string: "mailto:a@b.c")!, URL(string: "file:///tmp/x")!])
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(fetched.isEmpty)
        XCTAssertNil(loader.preview)
    }

    func testCacheServesSecondLoadWithoutFetching() async {
        let unique = URL(string: "https://example.com/\(UUID().uuidString).png")!
        var fetchCount = 0
        let fetch: ImageURLPreviewLoader.Fetch = { [png] _ in fetchCount += 1; return png }
        let first = ImageURLPreviewLoader(fetch: fetch)
        first.load(urls: [unique])
        _ = await waitForPreview(first)
        let second = ImageURLPreviewLoader(fetch: fetch)
        second.load(urls: [unique])
        XCTAssertEqual(second.preview?.data, png) // synchronous cache hit
        XCTAssertEqual(fetchCount, 1)
    }
}
```

Note: the `fetch` closures above capture mutable state from the test — mark the captured vars appropriately if the compiler demands `@Sendable` purity (e.g. use a small `final class Counter: @unchecked Sendable` box for `fetchCount`/`fetched` if needed).

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ImageURLPreviewLoaderTests`
Expected: compile FAILURE.

- [ ] **Step 3: Implement**

Create `Sources/PagerCore/Images/ImageURLPreviewLoader.swift`:

```swift
import Foundation

/// Mode 4: a text message contains an image URL → lazily fetch it when the
/// popover opens and show a preview. Pure presentation — nothing on the wire.
/// Fetching happens on the RECEIVER at display time (a sender-side flag would
/// save nothing: the receiver still has to fetch, and stored flags go stale).
@MainActor
public final class ImageURLPreviewLoader: ObservableObject {
    public struct Preview: Equatable {
        public let url: URL
        public let data: Data
    }

    @Published public private(set) var preview: Preview?

    public typealias Fetch = @Sendable (URL) async throws -> Data

    private let fetch: Fetch
    private var task: Task<Void, Never>?

    /// Session-lifetime cache so reopening the popover is instant.
    private static var cache: [URL: Data] = [:]
    private static var cacheOrder: [URL] = []
    private static let cacheCapacity = 20

    public init(fetch: @escaping Fetch = ImageURLPreviewLoader.urlSessionFetch) {
        self.fetch = fetch
    }

    /// Tries the URLs in order; the first response that decodes as an image
    /// wins. Failures are silent (the popover just shows the link row).
    public func load(urls: [URL]) {
        task?.cancel()
        preview = nil
        let candidates = urls.filter { $0.scheme == "http" || $0.scheme == "https" }
        guard !candidates.isEmpty else { return }
        for url in candidates {
            if let data = Self.cache[url] {
                preview = Preview(url: url, data: data)
                return
            }
        }
        task = Task { [fetch] in
            for url in candidates {
                guard !Task.isCancelled else { return }
                guard let data = try? await fetch(url),
                      ImageCodec.isDecodableImage(data) else { continue }
                Self.store(data, for: url)
                preview = Preview(url: url, data: data)
                return
            }
        }
    }

    private static func store(_ data: Data, for url: URL) {
        if cache[url] == nil {
            cacheOrder.append(url)
            if cacheOrder.count > cacheCapacity {
                cache[cacheOrder.removeFirst()] = nil
            }
        }
        cache[url] = data
    }

    public static let maxBytes = 10 * 1024 * 1024

    public static let urlSessionFetch: Fetch = { url in
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) { throw URLError(.badServerResponse) }
        guard data.count <= maxBytes else { throw URLError(.dataLengthExceedsMaximum) }
        return data
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ImageURLPreviewLoaderTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/PagerCore/Images Tests/PagerCoreTests
git commit -m "feat: ImageURLPreviewLoader — lazy receiver-side image-URL previews"
```

---

### Task 11: Menu bar thumbnail rendering

**Files:**
- Modify: `Sources/Pager/App/StatusItemController.swift`
- Modify: `Sources/Pager/App/AppDelegate.swift` (reconcile)

**Interfaces:**
- Consumes: `PagerContent` (Task 1), `ImageDisplayMath.boxSize` (Task 8), `LinkStore.cachedContent` (Task 4).
- Produces: `StatusItemController.render(content: PagerContent, prefs: AppearancePrefs)` — the old `render(text:prefs:)` becomes the private text path.

No unit tests (Pager target has none — GUI last mile); verification is `swift build` + the manual checklist in Task 14.

- [ ] **Step 1: Implement the content-switching render**

In `StatusItemController`, rename the existing `render(text:prefs:)` to `private func renderText(_ text: String, prefs: AppearancePrefs)` and add at the top of its body (after the `guard let button`):

```swift
        button.image = nil
        button.imagePosition = .noImage
```

Then add:

```swift
    func render(content: PagerContent, prefs: AppearancePrefs) {
        switch content {
        case .text(let text): renderText(text, prefs: prefs)
        case .image(let data): renderImage(data, prefs: prefs)
        }
    }

    private func renderImage(_ data: Data, prefs: AppearancePrefs) {
        guard let button = statusItem.button,
              let thumbnail = Self.thumbnail(from: data, maxWidth: prefs.maxWidth) else {
            renderText("", prefs: prefs) // unreadable cache → placeholder 📟
            return
        }
        button.attributedTitle = NSAttributedString(string: "")
        button.image = thumbnail
        button.imagePosition = .imageOnly
    }
```

- [ ] **Step 2: Implement the thumbnail composer** (same file)

```swift
    // Thumbnail geometry: 2pt border in the OS menu-bar text color, 1pt gap,
    // then the image (~16pt tall) — total 22pt, the status bar thickness.
    static let thumbBorderWidth: CGFloat = 2
    static let thumbBorderGap: CGFloat = 1
    static let thumbInnerHeight: CGFloat = 16

    /// Composes the bordered, aspect-clamped menu bar thumbnail. Drawn via a
    /// drawingHandler so labelColor adapts to light/dark at draw time.
    static func thumbnail(from data: Data, maxWidth: Double) -> NSImage? {
        guard let source = NSImage(data: data),
              source.size.width > 0, source.size.height > 0 else { return nil }
        let inset = thumbBorderWidth + thumbBorderGap
        let box = ImageDisplayMath.boxSize(
            imageSize: CGSize(width: source.size.width, height: source.size.height),
            maxWidth: max(Double(maxWidth) - 2 * Double(inset), 8),
            maxHeight: Double(thumbInnerHeight))
        guard box != .zero else { return nil }
        let total = NSSize(width: box.width + 2 * inset, height: box.height + 2 * inset)
        let image = NSImage(size: total, flipped: false) { rect in
            let borderRect = rect.insetBy(dx: thumbBorderWidth / 2, dy: thumbBorderWidth / 2)
            let border = NSBezierPath(roundedRect: borderRect, xRadius: 4, yRadius: 4)
            border.lineWidth = thumbBorderWidth
            NSColor.labelColor.setStroke()
            border.stroke()
            let boxRect = rect.insetBy(dx: inset, dy: inset)
            let fitted = Self.fitRect(imageSize: source.size, in: boxRect)
            NSBezierPath(roundedRect: fitted, xRadius: 2, yRadius: 2).setClip()
            source.draw(in: fitted, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Aspect-fit rect for an image centered in a box (letterbox bars stay
    /// transparent — the menu bar background shows through).
    static func fitRect(imageSize: NSSize, in box: NSRect) -> NSRect {
        let scale = min(box.width / imageSize.width, box.height / imageSize.height)
        let size = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return NSRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
```

- [ ] **Step 3: Route content through `AppDelegate.reconcile`**

In `reconcile(links:)`, replace `controllers[link.id]?.render(text: link.cachedText, prefs: link.appearance)` with:

```swift
            controllers[link.id]?.render(content: store.cachedContent(id: link.id),
                                         prefs: link.appearance)
```

- [ ] **Step 4: Build**

Run: `swift build && swift test`
Expected: builds clean; tests untouched.

- [ ] **Step 5: Commit**

```bash
git add Sources/Pager
git commit -m "feat: menu bar renders image content as bordered, aspect-clamped thumbnail"
```

---

### Task 12: Drop on the status item

**Files:**
- Create: `Sources/Pager/App/StatusItemDropView.swift`
- Modify: `Sources/Pager/App/StatusItemController.swift`
- Modify: `Sources/Pager/App/AppDelegate.swift`

**Interfaces:**
- Consumes: `DropPayload`/`DropPayloadClassifier` (Task 9), `EditorSession` (Task 6), `SyncEngine: ContentCommitter` (Task 5).
- Produces: `StatusItemController.onDropPayload: ((DropPayload) -> Void)?`; `AppDelegate.handleDrop(_:linkId:)` — drop = edit + commit in one step (immediate PUT, no popover).

- [ ] **Step 1: Implement the drag-destination overlay**

Create `Sources/Pager/App/StatusItemDropView.swift`:

```swift
import AppKit
import PagerCore

/// Transparent overlay filling the status item button: accepts drags (image
/// data, image files, text) and reports the classified payload. Mouse clicks
/// are forwarded to the button underneath so the popover toggle still works.
final class StatusItemDropView: NSView {
    var onDrop: ((DropPayload) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .png, .tiff, .string])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func mouseDown(with event: NSEvent) {
        superview?.mouseDown(with: event) // let the NSStatusBarButton handle clicks
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        var imageDatas: [Data] = []
        // Direct image data (browser drags, screenshot floats).
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type) { imageDatas.append(data) }
        }
        // Dropped files (Finder): read contents; the classifier decides if
        // they're images. Non-image files simply won't classify.
        let fileURLs = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        for url in fileURLs {
            if let data = try? Data(contentsOf: url) { imageDatas.append(data) }
        }
        let strings = pasteboard.readObjects(forClasses: [NSString.self]) as? [String] ?? []
        guard let payload = DropPayloadClassifier.classify(
            imageDatas: imageDatas, strings: strings) else {
            NSSound.beep()
            return false
        }
        onDrop?(payload)
        return true
    }
}
```

- [ ] **Step 2: Mount it in `StatusItemController`**

Add the property and callback:

```swift
    private let dropView = StatusItemDropView()
    /// Fired when something is dropped on the menu bar item. AppDelegate wires
    /// this to an immediate edit+commit (no popover involved).
    var onDropPayload: ((DropPayload) -> Void)?
```

and in `init`, inside the existing `if let button = statusItem.button` block (after the `anchorView` line):

```swift
            dropView.frame = button.bounds
            dropView.autoresizingMask = [.width, .height]
            dropView.onDrop = { [weak self] payload in self?.onDropPayload?(payload) }
            button.addSubview(dropView)
```

- [ ] **Step 3: Wire the drop action in `AppDelegate`**

In `addController(for:)`, after the `makePopoverContent` assignment:

```swift
        controller.onDropPayload = { [weak self] payload in
            self?.handleDrop(payload, linkId: linkId)
        }
```

and add the handler:

```swift
    /// Drop on the menu bar item = edit + commit in one step. Dropping on the
    /// shared line is deliberately "send this" — no popover, no draft.
    private func handleDrop(_ payload: DropPayload, linkId: UUID) {
        guard let engine = engines[linkId] else { NSSound.beep(); return }
        let session = EditorSession(linkId: linkId, store: store, committer: engine)
        switch payload {
        case .image(let raw):
            do { try session.setImage(raw) } catch { NSSound.beep(); return }
        case .text(let text):
            session.edit(text)
        }
        session.commit()
    }
```

(`session.commit()` → `engine.commitContent` + `store.updateCachedContent` → `store.$links` fires → `reconcile` re-renders the item. No extra render call needed.)

- [ ] **Step 4: Build**

Run: `swift build && swift test`
Expected: clean.

- [ ] **Step 5: Commit**

```bash
git add Sources/Pager
git commit -m "feat: drop text/images on the menu bar item — instant classify + commit"
```

---

### Task 13: Popover — image display, paste, ✕, click-to-open, URL preview

**Files:**
- Create: `Sources/Pager/UI/PagerImageView.swift`
- Modify: `Sources/Pager/UI/LinkViewModel.swift`
- Modify: `Sources/Pager/UI/PopoverView.swift`

**Interfaces:**
- Consumes: `EditorSession.setImage/clearImage/draftImageData` (Task 6), `ImageURLPreviewLoader` (Task 10), `ImageDisplayMath` (Task 8), `DropPayloadClassifier` (Task 9).
- Produces: `LinkViewModel.draftImage: Data?`, `imageError: String?`, `previewLoader: ImageURLPreviewLoader`, `pasteFromGeneralPasteboard()`, `clearImage()`, `openDraftImage()`; `PagerImageView(imageData:onTap:onClear:)`.

- [ ] **Step 1: Extend `LinkViewModel`**

Add the published state and the preview loader:

```swift
    @Published var draftImage: Data?
    @Published var imageError: String?
    let previewLoader = ImageURLPreviewLoader()
```

In `init`, after `self.detectedURLs = session.detectedURLs`:

```swift
        self.draftImage = session.draftImageData
        previewLoader.load(urls: session.detectedURLs.map(\.url))
```

Replace `textEdited()` with (the equality guard stops the programmatic `text = ""` after an image paste from wiping the image draft):

```swift
    /// Called from the view's onChange. Keeps `detectedURLs`/cap in sync with
    /// the session after it has processed the edit. The guard skips
    /// programmatic syncs (e.g. text set to "" after an image paste) — only a
    /// real user edit may replace an image draft.
    func textEdited() {
        guard text != session.text else { return }
        session.edit(text)
        if text != session.text { text = session.text } // reflect the char cap
        detectedURLs = session.detectedURLs
        draftImage = nil
        imageError = nil
        previewLoader.load(urls: detectedURLs.map(\.url))
    }
```

Add the image actions:

```swift
    /// ⌘V with an image (or image file) on the pasteboard. The image becomes
    /// the DRAFT — committed on popover close, exactly like typed text.
    func pasteFromGeneralPasteboard() {
        let pasteboard = NSPasteboard.general
        var imageDatas: [Data] = []
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type) { imageDatas.append(data) }
        }
        let fileURLs = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        for url in fileURLs {
            if let data = try? Data(contentsOf: url) { imageDatas.append(data) }
        }
        guard case .image(let raw)? = DropPayloadClassifier.classify(
            imageDatas: imageDatas, strings: []) else { return }
        do {
            try session.setImage(raw)
            draftImage = session.draftImageData
            text = ""
            detectedURLs = []
            imageError = nil
        } catch {
            imageError = "couldn't read that image"
        }
    }

    /// The ✕ on the image: back to an empty text draft.
    func clearImage() {
        session.clearImage()
        draftImage = nil
    }

    /// Click on the draft image: hand the bytes to Preview (copy/save/share
    /// come free there — no need to build those buttons).
    func openDraftImage() {
        guard let data = draftImage else { return }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Pager", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(linkId.uuidString).jpg")
        try? data.write(to: url, options: .atomic)
        NSWorkspace.shared.open(url)
    }
```

(`LinkViewModel` already imports SwiftUI; add `import AppKit` if the compiler asks for it.)

- [ ] **Step 2: Create `PagerImageView`**

Create `Sources/Pager/UI/PagerImageView.swift`:

```swift
import SwiftUI
import PagerCore

/// Clickable image box shared by the draft image and the URL preview: aspect
/// clamped to ≥ 9:16 (taller images letterbox on bars slightly darker than the
/// popover background), pointer cursor + subtle dim on hover, optional ✕.
struct PagerImageView: View {
    let imageData: Data
    let onTap: () -> Void
    var onClear: (() -> Void)?
    @State private var hovering = false

    /// Popover is 360pt wide with 16pt padding.
    static let maxWidth: Double = 328
    static let maxHeight: Double = 240

    var body: some View {
        if let nsImage = NSImage(data: imageData) {
            let box = ImageDisplayMath.boxSize(
                imageSize: CGSize(width: nsImage.size.width, height: nsImage.size.height),
                maxWidth: Self.maxWidth, maxHeight: Self.maxHeight)
            ZStack(alignment: .topTrailing) {
                ZStack {
                    Color.primary.opacity(0.06) // letterbox bars
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFit()
                    if hovering { Color.black.opacity(0.1) }
                }
                if hovering, let onClear {
                    Button(action: onClear) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.white, .black.opacity(0.55))
                            .font(.system(size: 16))
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                }
            }
            .frame(width: box.width, height: box.height)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
    }
}
```

- [ ] **Step 3: Wire up `PopoverView`**

Add the second observed object (nested `ObservableObject`s don't republish through `model`):

```swift
struct PopoverView: View {
    @ObservedObject var model: LinkViewModel
    @ObservedObject var updates: UpdateController
    @ObservedObject var previews: ImageURLPreviewLoader
    @FocusState private var focused: Bool

    init(model: LinkViewModel, updates: UpdateController) {
        self.model = model
        self.updates = updates
        self.previews = model.previewLoader
    }
```

Add `import UniformTypeIdentifiers` at the top. On the `TextField`, chain after `.onSubmit { ... }`:

```swift
                .onPasteCommand(of: [UTType.image, UTType.fileURL]) { _ in
                    model.pasteFromGeneralPasteboard()
                }
```

After the `detectedURLs` block (and before the offline hint), insert:

```swift
            if let error = model.imageError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let draft = model.draftImage {
                PagerImageView(
                    imageData: draft,
                    onTap: { model.openDraftImage() },
                    onClear: { model.clearImage() })
            } else if let preview = previews.preview {
                PagerImageView(
                    imageData: preview.data,
                    onTap: { NSWorkspace.shared.open(preview.url) },
                    onClear: nil)
            }
```

- [ ] **Step 4: Build and manually verify the paste path**

Run: `swift build && swift test`, then `make bundle && open dist/Pager.app`. Take a screenshot region to the clipboard (⌘⇧⌃4), open the popover, hit ⌘V. Expected: image appears as the draft; closing the popover commits it.

**Contingency (only if ⌘V does nothing because the field editor swallows it before `.onPasteCommand`):** attach the paste command to the whole `VStack` instead of the `TextField`, and if that also fails, replace it with an explicit key monitor owned by the view model — add to `LinkViewModel`:

```swift
    private var pasteMonitor: Any?

    /// Installed while the popover is open (PopoverView.onAppear). Intercepts
    /// ⌘V only when this popover's window is key AND the pasteboard holds an
    /// image — everything else passes through to the text field.
    func installPasteMonitor() {
        guard pasteMonitor == nil else { return }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.modifierFlags.contains(.command),
                  event.charactersIgnoringModifiers == "v",
                  event.window?.isKeyWindow == true,
                  event.window?.contentViewController is NSHostingController<PopoverView>
            else { return event }
            let pb = NSPasteboard.general
            let hasImage = pb.data(forType: .png) != nil || pb.data(forType: .tiff) != nil
            guard hasImage else { return event }
            self.pasteFromGeneralPasteboard()
            return nil
        }
    }

    func removePasteMonitor() {
        if let monitor = pasteMonitor { NSEvent.removeMonitor(monitor) }
        pasteMonitor = nil
    }
```

with `.onAppear { model.installPasteMonitor() }` in `PopoverView`, and `removePasteMonitor()` called from the popover-close path (`AppDelegate.popoverContent`'s `controllers[linkId]?.onClose` closure, alongside `model?.commit()` — NOT `.onDisappear`, which fires late; see the commit-on-close spec).

- [ ] **Step 5: Commit**

```bash
git add Sources/Pager
git commit -m "feat: popover image mode — paste, display, clear, click-to-open, URL previews"
```

---

### Task 14: Firebase rules, docs, e2e image scenario, final verification

**Files:**
- Modify: `firebase/rules.json`
- Modify: `docs/firebase-setup.md`
- Modify: `AGENTS.md` (CLAUDE.md is a symlink to it)
- Modify: `Sources/E2E/main.swift`

**Interfaces:**
- Consumes: everything above.

- [ ] **Step 1: Update `firebase/rules.json`** — full new content:

```json
{
  "rules": {
    ".read": false,
    ".write": false,
    "pagers": {
      "$pathId": {
        ".read": true,
        ".write": true,
        ".validate": "newData.hasChildren(['ct', 'writtenAt', 'updatedAt', 'updatedBy'])",
        "type": { ".validate": "newData.isString() && (newData.val() === 'text' || newData.val() === 'img')" },
        "ct": { ".validate": "newData.isString() && ((newData.parent().child('type').val() === 'img' && newData.val().length <= 1000000) || (newData.parent().child('type').val() !== 'img' && newData.val().length <= 2048))" },
        "writtenAt": { ".validate": "newData.isNumber()" },
        "updatedAt": { ".validate": "newData.isNumber()" },
        "updatedBy": { ".validate": "newData.isString() && newData.val().length <= 64" },
        "$other": { ".validate": false }
      }
    }
  }
}
```

(`type` is optional — `hasChildren` doesn't list it; absent ⇒ text, and the conditional keeps text `ct` at the old 2 KB cap while img gets 1,000,000 chars ≈ 750 KB binary.)

- [ ] **Step 2: STOP — ask your human partner to apply the rules**

The updated `firebase/rules.json` must be pasted into the Firebase console (Realtime Database → Rules → Publish) **before** the e2e run or any image commit against the live DB — old rules reject nodes with a `type` key (`$other: false`). Ask Jeroen to apply them now; do not proceed to Step 4 until confirmed.

- [ ] **Step 3: Extend the e2e harness** — in `Sources/E2E/main.swift`:

Track image views next to the text views (top of `run()`, where `aView`/`bView` are declared):

```swift
        var aImage: Data?
        var bImage: Data?
        a.onContent = { c, _ in aView = c.textValue; aImage = c.imageData }
        b.onContent = { c, _ in bView = c.textValue; bImage = c.imageData }
```

(replacing the two existing `onContent` closures). After scenario 4 (reconnect) and before the logging checks, insert:

```swift
        // 6. Image content: A commits an image → B receives byte-identical
        //    data; a text reply replaces it on both ends; text writes stay
        //    typeless on the wire (back-compat with old clients).
        let jpeg = try! ImageCodec.process(E2E.stripedPNG(width: 1400, height: 900))
        a.commitContent(.image(jpeg))
        check("A→B image propagation (byte-identical)", await waitUntil { bImage == jpeg })
        let afterImage = "text-again-\(nonce())"
        commitB(afterImage)
        check("text replaces the image on both ends",
              await waitUntil { aView == afterImage && bView == afterImage && bImage == nil })
        // Raw node JSON for a text write must have no "type" key.
        var rawReq = URLRequest(url: dbURL.appendingPathComponent("pagers/\(pathId).json"))
        let rawJSON = (try? await URLSession.shared.data(for: rawReq).0).map {
            String(decoding: $0, as: UTF8.self) } ?? ""
        check("text nodes carry no type field (legacy shape)", !rawJSON.contains("\"type\""))
```

and add the fixture helper to the `E2E` enum (CoreGraphics, mirrors the unit-test factory):

```swift
    /// Deterministic striped PNG (same idea as the unit tests' TestImageFactory).
    static func stripedPNG(width: Int, height: Int) -> Data {
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for x in stride(from: 0, to: width, by: 16) {
            let shade = CGFloat(x % 256) / 255
            ctx.setFillColor(CGColor(red: shade, green: 1 - shade, blue: 0.5, alpha: 1))
            ctx.fill(CGRect(x: x, y: 0, width: 16, height: height))
        }
        let image = ctx.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(
            out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }
```

with `import CoreGraphics`, `import ImageIO`, `import UniformTypeIdentifiers` added at the top of `main.swift`. Note the mutation-guard: `var rawReq` is fine as `let` if the compiler warns — use `let`.

Also note for the log-assertion section already in the file: image events log `ct_len` instead of `ct`, so the existing "logged ciphertext decrypts" checks (which filter on text messages `m1`) keep passing unchanged.

- [ ] **Step 4: Run the live e2e**

Run: `swift run e2e`
Expected: exit 0, all checks green including the three new image checks. (Requires Step 2 done.)

- [ ] **Step 5: Update docs**

`docs/firebase-setup.md` — add a dated note at the point where rules are applied: image support (2026-08) changed `firebase/rules.json` (optional `type` field, conditional `ct` cap); existing databases must re-publish the rules from the repo.

`AGENTS.md` — surgical updates only:
- "What this is" gains one sentence: a pager can also hold an E2E-encrypted image (dropped on the menu bar item or pasted in the popover), re-encoded to JPEG ≤ 600 KB and stored inline in the same node (`type: "img"`).
- `PagerCore layers`: add `Images/` — `ImageCodec` (ImageIO downscale/encode), `ImageDisplayMath` (9:16-clamped boxes), `DropPayloadClassifier` (drop/paste decision), `ImageURLPreviewLoader` (receiver-side URL previews). Note `Models/ImageDiskCache` (decrypted image cache on disk; `UserDefaults` holds only `cachedIsImage`).
- Key invariants: add "A pager holds text OR an image, never both — the wire discriminator is the optional `type` field (absent ⇒ text); the code discriminator is `PagerContent`, parsed once at the sync boundary" and "img log events carry `ct_len`, never the image ciphertext".
- Diagnostics section: one line noting img events log length only.

- [ ] **Step 6: Full offline suite one last time**

Run: `swift build && swift test`
Expected: PASS.

- [ ] **Step 7: Manual GUI verification checklist** (the residual last mile — run through with `make bundle && open dist/Pager.app`):

1. Drop an image file from Finder on the menu bar item → bordered thumbnail appears; other device (or second link with same code) shows it ~1 s later.
2. Drop a screenshot floating thumbnail on the item → same.
3. Drag selected text from an editor onto the item → text commits instantly.
4. Drop a random non-image file (e.g. a .pdf) → beep, nothing changes.
5. Click the item → popover shows empty text field ("type a message…") + the image; hover shows pointer + dim + ✕; click opens Preview.
6. ✕ then close → other side shows 📟 (empty).
7. ⌘⇧⌃4 region → ⌘V in popover → image drafts; close → commits.
8. Type over an image draft → text replaces it on commit.
9. Paste a message containing a direct image URL → link row + preview appear; clicking the preview opens the browser; menu bar shows the text.
10. Menu bar thumbnail border legible in both light and dark mode; very tall image letterboxes at 9:16 in the popover.
11. Quit + relaunch with an image cached → thumbnail renders with no network.

- [ ] **Step 8: Commit**

```bash
git add firebase/rules.json docs Sources/E2E AGENTS.md
git commit -m "feat: image support — rules, docs, live e2e image round-trip"
```

---

## Self-review notes

- **Spec coverage:** wire format + back-compat (T1), compression pipeline (T2), single decrypt boundary (T3), disk cache + never-blank menu bar (T4), engine + `ct_len` logging (T5), draft semantics incl. paste-is-draft (T6, T13), join-with-image (T7), 9:16 clamp both displays (T8, T11, T13), drop classification (T9), mode-4 previews receiver-side (T10, T13), bordered thumbnail (T11), drop = instant commit (T12), conditional rules cap + docs + e2e (T14). Out-of-scope items from the spec (captions, Cloud Storage, drop-on-popover, menu-bar previews for mode 4) appear in no task.
- **Type consistency check:** `PagerContent.imageWireType`/`wireType`/`textValue`/`imageData`/`sizeForLog` (T1) are the names used in T3, T5, T6, T14. `ContentCommitter.commitContent` (T5) is what T6's stub and T12's `handleDrop` rely on. `updateCachedContent`/`cachedContent` (T4) used in T5–T7, T11, T12. `ImageDisplayMath.boxSize` (T8) used in T11, T13. `DropPayloadClassifier.classify(imageDatas:strings:)` (T9) used in T12, T13.
- **Known judgment calls encoded here:** text writes omit `type` (back-compat); paste = draft but drop = instant commit; join surfaces no `friendMessage` for images; the paste-command contingency is pre-written rather than left to discover.
