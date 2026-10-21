import XCTest
@testable import LocalBrainKit

final class InputInterlockTests: XCTestCase {
    func testMouseTravelStopsAtTheThreshold() {
        XCTAssertFalse(InputInterlock.shouldStop(mouseTravel: 0))
        XCTAssertFalse(InputInterlock.shouldStop(mouseTravel: InputInterlock.mouseMoveStopPoints - 0.1))
        XCTAssertTrue(InputInterlock.shouldStop(mouseTravel: InputInterlock.mouseMoveStopPoints))
        XCTAssertTrue(InputInterlock.shouldStop(mouseTravel: 300))
    }

    func testAgentKeyEventsNeverStopTheRun() {
        XCTAssertFalse(InputInterlock.shouldStop(keyDownWithUserData: InputInterlock.agentEventTag))
        XCTAssertTrue(InputInterlock.shouldStop(keyDownWithUserData: 0))
        XCTAssertTrue(InputInterlock.shouldStop(keyDownWithUserData: InputInterlock.agentEventTag + 1))
    }
}
