import XCTest
@testable import PagerCore

final class SSEParserTests: XCTestCase {
    func testParsesSinglePutEvent() {
        let parser = SSEParser()
        let events = parser.feed(Data("event: put\ndata: {\"path\":\"/\",\"data\":null}\n\n".utf8))
        XCTAssertEqual(events, [SSEEvent(name: "put", data: "{\"path\":\"/\",\"data\":null}")])
    }

    func testParsesKeepAlive() {
        let parser = SSEParser()
        let events = parser.feed(Data("event: keep-alive\ndata: null\n\n".utf8))
        XCTAssertEqual(events, [SSEEvent(name: "keep-alive", data: "null")])
    }

    func testBuffersAcrossChunkBoundaries() {
        let parser = SSEParser()
        XCTAssertEqual(parser.feed(Data("event: pu".utf8)), [])
        XCTAssertEqual(parser.feed(Data("t\ndata: {\"a\":1".utf8)), [])
        let events = parser.feed(Data("}\n\nevent: keep-alive\ndata: null\n\n".utf8))
        XCTAssertEqual(events, [
            SSEEvent(name: "put", data: "{\"a\":1}"),
            SSEEvent(name: "keep-alive", data: "null"),
        ])
    }

    func testMultipleEventsInOneChunk() {
        let parser = SSEParser()
        let raw = "event: put\ndata: 1\n\nevent: put\ndata: 2\n\n"
        XCTAssertEqual(parser.feed(Data(raw.utf8)).map(\.data), ["1", "2"])
    }

    func testMultiLineDataIsJoined() {
        let parser = SSEParser()
        let events = parser.feed(Data("event: put\ndata: line1\ndata: line2\n\n".utf8))
        XCTAssertEqual(events, [SSEEvent(name: "put", data: "line1\nline2")])
    }

    func testIgnoresEmptyBlocksAndComments() {
        let parser = SSEParser()
        XCTAssertEqual(parser.feed(Data("\n\n: comment\n\n".utf8)), [])
    }
}
