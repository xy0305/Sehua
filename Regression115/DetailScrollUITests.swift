import XCTest

final class DetailScrollUITests: XCTestCase {
    func testBottomThenBackToTopAndExplicitPagination() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let scroll = app.scrollViews.firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: 40))
        let title = app.otherElements["detail-scroll-title"]
        let top = app.descendants(matching: .any)["detail-scroll-title"]
        XCTAssertTrue(top.waitForExistence(timeout: 20))
        let more = app.buttons["加载更多回复"]
        var down = 0
        while !more.isHittable && down < 65 {
            scroll.swipeUp(velocity: .slow)
            down += 1
        }
        XCTAssertTrue(more.isHittable, "must reach page-one bottom")
        let initialBottom = XCTAttachment(screenshot: app.screenshot())
        initialBottom.name = "detail-page-one-bottom"; initialBottom.lifetime = .keepAlways; add(initialBottom)
        var initialUp = 0
        while !top.isHittable && initialUp < 75 {
            scroll.swipeDown(velocity: .slow); initialUp += 1
        }
        XCTAssertTrue(top.isHittable, "page-one bottom-to-top must work before any pagination request")
        let initialTop = XCTAttachment(screenshot: app.screenshot())
        initialTop.name = "detail-page-one-returned-top"; initialTop.lifetime = .keepAlways; add(initialTop)
        print("SCROLL UI initial bottom swipes=\(down), return-to-top swipes=\(initialUp)")
        var secondDown = 0
        while !more.isHittable && secondDown < 65 {
            scroll.swipeUp(velocity: .slow); secondDown += 1
        }
        XCTAssertTrue(more.isHittable)
        // A failed page must remain an explicit button, never an onAppear retry.
        more.tap()
        let error = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "未取得下一页回复")).firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 30))
        let firstCount = try pageTwoCount()
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(try pageTwoCount(), firstCount, "failure must not automatically retry")
        XCTAssertEqual(firstCount, 1)
        more.tap()
        let pageTwo = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "已加载至第2页")).firstMatch
        XCTAssertTrue(pageTwo.waitForExistence(timeout: 30))
        XCTAssertEqual(try pageTwoCount(), 2)
        // Reach real bottom after appending; then repeatedly swipe toward top.
        scroll.swipeUp(velocity: .slow)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "detail-bottom-after-pagination"; shot.lifetime = .keepAlways; add(shot)
        var up = 0
        while !top.isHittable && up < 75 {
            scroll.swipeDown(velocity: .slow)
            up += 1
        }
        XCTAssertTrue(top.isHittable, "bottom-to-top gestures must not become trapped in lazy image collapse/redecode loop")
        let back = XCTAttachment(screenshot: app.screenshot())
        back.name = "detail-returned-to-top"; back.lifetime = .keepAlways; add(back)
        print("SCROLL UI page-one bottom swipes=\(down), bottom-to-top swipes=\(up), page2 requests=2")
        // Repeat once to catch reappearance rather than just first decode.
        var repeatDown = 0
        while !pageTwo.isHittable && repeatDown < 65 {
            scroll.swipeUp(velocity: .slow); repeatDown += 1
        }
        XCTAssertTrue(pageTwo.isHittable)
        var repeatUp = 0
        while !top.isHittable && repeatUp < 75 {
            scroll.swipeDown(velocity: .slow); repeatUp += 1
        }
        XCTAssertTrue(top.isHittable)
        XCTAssertEqual(try pageTwoCount(), 2, "scrolling alone must not fetch replies")
        _ = title
    }

    private func pageTwoCount() throws -> Int {
        let done = expectation(description: "loopback statistics")
        let box = StatsBox()
        URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:18766/stats")!) { data, _, _ in
            if let data { box.value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Int] }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
        return try XCTUnwrap(box.value?["page2"])
    }
}
private final class StatsBox: @unchecked Sendable { var value: [String: Int]? }
