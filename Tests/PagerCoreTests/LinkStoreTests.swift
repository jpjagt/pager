import XCTest
@testable import PagerCore

final class LinkStoreTests: XCTestCase {
    var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: "LinkStoreTests")!
        defaults.removePersistentDomain(forName: "LinkStoreTests")
    }

    func testDeviceIdIsStable() {
        let a = LinkStore(defaults: defaults).deviceId
        let b = LinkStore(defaults: defaults).deviceId
        XCTAssertEqual(a, b)
        XCTAssertFalse(a.isEmpty)
    }

    func testAddAssignsDefaultNicknameAndPersists() {
        let store = LinkStore(defaults: defaults)
        let code = ShareCode.generate()
        let link = store.add(code: code)
        XCTAssertEqual(link.nickname, "Pager 1")
        XCTAssertEqual(store.add(code: ShareCode.generate()).nickname, "Pager 2")

        let reloaded = LinkStore(defaults: defaults)
        XCTAssertEqual(reloaded.links.count, 2)
        XCTAssertEqual(reloaded.links[0].code, code.full)
    }

    func testRemove() {
        let store = LinkStore(defaults: defaults)
        let link = store.add(code: ShareCode.generate())
        store.remove(id: link.id)
        XCTAssertTrue(store.links.isEmpty)
        XCTAssertTrue(LinkStore(defaults: defaults).links.isEmpty)
    }

    func testUpdateCachedTextPersists() {
        let store = LinkStore(defaults: defaults)
        let link = store.add(code: ShareCode.generate())
        store.updateCachedText(id: link.id, text: "hello", writtenAt: 123)
        let reloaded = LinkStore(defaults: defaults)
        XCTAssertEqual(reloaded.links[0].cachedText, "hello")
        XCTAssertEqual(reloaded.links[0].cachedWrittenAt, 123)
    }

    func testUpdateLinkPersistsAppearanceAndNickname() {
        let store = LinkStore(defaults: defaults)
        var link = store.add(code: ShareCode.generate())
        link.nickname = "Tom"
        link.appearance.maxWidth = 150
        link.appearance.fontSize = 15
        link.appearance.screenColor = .pink
        link.appearance.caseColor = .beige
        store.update(link)
        let reloaded = LinkStore(defaults: defaults).links[0]
        XCTAssertEqual(reloaded.nickname, "Tom")
        XCTAssertEqual(reloaded.appearance.maxWidth, 150)
        XCTAssertEqual(reloaded.appearance.screenColor, .pink)
        XCTAssertEqual(reloaded.appearance.caseColor, .beige)
    }

    func testShareCodeAccessor() {
        let store = LinkStore(defaults: defaults)
        let code = ShareCode.generate()
        let link = store.add(code: code)
        XCTAssertEqual(link.shareCode, code)
    }

    func testUpdateMetaPreservesNewerCachedText() {
        let store = LinkStore(defaults: defaults)
        let stale = store.add(code: ShareCode.generate()) // snapshot before sync
        store.updateCachedText(id: stale.id, text: "fresh message", writtenAt: 999)
        store.updateMeta(id: stale.id, nickname: "Tom", appearance: stale.appearance)
        XCTAssertEqual(store.links[0].nickname, "Tom")
        XCTAssertEqual(store.links[0].cachedText, "fresh message")
        XCTAssertEqual(store.links[0].cachedWrittenAt, 999)
    }

    func testCachedContentImageRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkstore-img-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LinkStore(defaults: defaults, imageCache: ImageDiskCache(directory: dir))
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
        let store = LinkStore(defaults: defaults, imageCache: cache)
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
        let store = LinkStore(defaults: defaults, imageCache: cache)
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
}
