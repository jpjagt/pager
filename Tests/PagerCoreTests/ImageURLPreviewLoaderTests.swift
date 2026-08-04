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
        final class Box: @unchecked Sendable {
            var fetched: [URL] = []
        }
        let box = Box()
        let loader = ImageURLPreviewLoader(fetch: { url in box.fetched.append(url); return Data() })
        loader.load(urls: [URL(string: "mailto:a@b.c")!, URL(string: "file:///tmp/x")!])
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(box.fetched.isEmpty)
        XCTAssertNil(loader.preview)
    }

    func testCacheServesSecondLoadWithoutFetching() async {
        final class Counter: @unchecked Sendable {
            var count = 0
        }
        let unique = URL(string: "https://example.com/\(UUID().uuidString).png")!
        let counter = Counter()
        let fetch: ImageURLPreviewLoader.Fetch = { [png] _ in counter.count += 1; return png }
        let first = ImageURLPreviewLoader(fetch: fetch)
        first.load(urls: [unique])
        _ = await waitForPreview(first)
        let second = ImageURLPreviewLoader(fetch: fetch)
        second.load(urls: [unique])
        XCTAssertEqual(second.preview?.data, png) // synchronous cache hit
        XCTAssertEqual(counter.count, 1)
    }

    func testStaleFetchDoesNotOverwriteFresherPreview() async {
        // Regression test for the cancellation race: a slow first load() is
        // superseded by a fast second load() before the slow fetch resolves.
        // The stale (cancelled) task must not clobber the fresher preview
        // once its fetch eventually completes.
        actor Gate {
            private var continuation: CheckedContinuation<Void, Never>?
            private var released = false

            func wait() async {
                if released { return }
                await withCheckedContinuation { continuation = $0 }
            }

            func release() {
                released = true
                continuation?.resume()
                continuation = nil
            }
        }

        let gate = Gate()
        let slowURL = URL(string: "https://example.com/slow.png")!
        let fastURL = URL(string: "https://example.com/fast.png")!
        let slowPNG = TestImageFactory.png(width: 10, height: 10)
        let fastPNG = png

        let loader = ImageURLPreviewLoader(fetch: { url in
            if url == slowURL {
                await gate.wait()
                return slowPNG
            }
            return fastPNG
        })

        loader.load(urls: [slowURL])
        try? await Task.sleep(nanoseconds: 50_000_000) // let the slow fetch start & suspend on the gate

        loader.load(urls: [fastURL])
        let preview = await waitForPreview(loader)
        XCTAssertEqual(preview?.url, fastURL)
        XCTAssertEqual(preview?.data, fastPNG)

        await gate.release()
        try? await Task.sleep(nanoseconds: 150_000_000) // give the stale task a chance to (wrongly) resume

        XCTAssertEqual(loader.preview?.url, fastURL)
        XCTAssertEqual(loader.preview?.data, fastPNG)
    }
}
