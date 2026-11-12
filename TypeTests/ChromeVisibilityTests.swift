import XCTest
import CoreGraphics
@testable import TypeApp

final class ChromeVisibilityTests: XCTestCase {
    private let still = CGPoint(x: 500, y: 400)

    /// A visible chrome that has just been hidden by a keystroke at `t`.
    private func hiddenChrome(at t: TimeInterval = 10) -> ChromeVisibility {
        var c = ChromeVisibility()
        _ = c.pointerMoved(to: still, at: 0)  // baseline pointer position
        XCTAssertTrue(c.hide(at: t))
        return c
    }

    func testTypingHidesOnce() {
        var c = ChromeVisibility()
        XCTAssertTrue(c.hide(at: 1), "first keystroke hides")
        XCTAssertFalse(c.hide(at: 1.1), "further keystrokes don't re-run the hide")
        XCTAssertFalse(c.hide(at: 2))
        XCTAssertFalse(c.isVisible)
    }

    func testStationaryPointerNeverShowsChrome() {
        // Content shifting under a still pointer reports the same position again and again.
        var c = hiddenChrome()
        for i in 1...20 {
            XCTAssertFalse(c.pointerMoved(to: still, at: 10 + Double(i)), "hover at the same spot is not movement")
        }
        XCTAssertFalse(c.isVisible)
    }

    func testSmallMovementBelowThresholdIsIgnored() {
        var c = hiddenChrome()
        XCTAssertFalse(c.pointerMoved(to: CGPoint(x: still.x + 3, y: still.y + 3), at: 20), "about 4pt is jitter")
        XCTAssertFalse(c.isVisible)
    }

    func testRealMovementShowsChrome() {
        var c = hiddenChrome()
        XCTAssertTrue(c.pointerMoved(to: CGPoint(x: still.x + 10, y: still.y), at: 20))
        XCTAssertTrue(c.isVisible)
    }

    func testMovementDuringGraceIsIgnoredThenCountsAfterwards() {
        var c = hiddenChrome(at: 10)
        XCTAssertFalse(c.pointerMoved(to: CGPoint(x: still.x + 20, y: still.y), at: 10.2),
                       "inside the 0.4s grace period after a hide")
        XCTAssertFalse(c.isVisible)
        XCTAssertTrue(c.pointerMoved(to: CGPoint(x: still.x + 40, y: still.y), at: 10.5),
                      "a new real movement after the grace period shows the chrome")
    }

    func testSlowMovementCountsFromLastRealPosition() {
        // Steps of 1pt: the threshold is measured from the last real position, so the sixth step shows.
        var c = hiddenChrome()
        var p = still
        for i in 1...5 {
            p.x += 1
            XCTAssertFalse(c.pointerMoved(to: p, at: 10 + Double(i)), "step \(i) is under 6pt")
        }
        p.x += 1
        XCTAssertTrue(c.pointerMoved(to: p, at: 16), "six points of real movement shows the chrome")
    }

    func testShowingIsOnlyReportedOnce() {
        var c = hiddenChrome()
        XCTAssertTrue(c.pointerMoved(to: CGPoint(x: still.x + 10, y: still.y), at: 20))
        XCTAssertFalse(c.pointerMoved(to: CGPoint(x: still.x + 20, y: still.y), at: 21), "already visible")
    }

    func testHideAfterShowWorksAgain() {
        var c = hiddenChrome()
        XCTAssertTrue(c.pointerMoved(to: CGPoint(x: still.x + 10, y: still.y), at: 20))
        XCTAssertTrue(c.hide(at: 30))
        XCTAssertFalse(c.isVisible)
    }
}
