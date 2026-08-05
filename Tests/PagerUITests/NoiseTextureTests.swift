import XCTest
@testable import PagerUI

final class NoiseTextureTests: XCTestCase {
    func testTileIsNonNilAnd128x128() {
        let tile = NoiseTexture.tile
        XCTAssertEqual(tile.size.width, 128)
        XCTAssertEqual(tile.size.height, 128)
    }

    func testTileIsCachedAcrossAccesses() {
        let first = NoiseTexture.tile
        let second = NoiseTexture.tile
        XCTAssertTrue(first === second, "NoiseTexture.tile must be generated once and cached, not per-access")
    }
}
