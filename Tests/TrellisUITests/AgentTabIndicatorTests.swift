import XCTest
import TrellisCore
@testable import TrellisUI

/// FR-AG10: a working agent shows on the tab's top edge and icon; every other state keeps its capsule.
final class AgentTabIndicatorTests: XCTestCase {
    func testWorkingHasNoCapsuleAndOtherStatesKeepTheirs() {
        XCTAssertNil(TabCapsuleKind.resolve(agentState: .working, waitingForInput: false))
        for state in [AgentState.needsInput, .done, .error] {
            XCTAssertEqual(TabCapsuleKind.resolve(agentState: state, waitingForInput: false), .agent(state))
        }
    }

    func testWorkingAgentNeverGainsTheInputCapsule() {
        XCTAssertNil(TabCapsuleKind.resolve(agentState: .working, waitingForInput: true))
    }

    func testAgentStateOutranksInputAndInputShowsWithoutAnAgent() {
        XCTAssertEqual(TabCapsuleKind.resolve(agentState: .needsInput, waitingForInput: true), .agent(.needsInput))
        XCTAssertEqual(TabCapsuleKind.resolve(agentState: nil, waitingForInput: true), .input)
        XCTAssertNil(TabCapsuleKind.resolve(agentState: nil, waitingForInput: false))
    }

    func testWorkingThreadReplacesTheBusyBarAndTheLabelStripe() {
        XCTAssertEqual(TabTopEdgeKind.resolve(hasProgress: false, agentState: .working, busy: true, hasLabel: true), .agentWorking)
    }

    func testProgressOutranksTheWorkingThread() {
        XCTAssertEqual(TabTopEdgeKind.resolve(hasProgress: true, agentState: .working, busy: true, hasLabel: true), .progress)
    }

    func testOtherAgentStatesLeaveTheBusyBarAndLabelAsBefore() {
        for state in [AgentState.needsInput, .done, .error] {
            XCTAssertEqual(TabTopEdgeKind.resolve(hasProgress: false, agentState: state, busy: true, hasLabel: true), .busy)
            XCTAssertEqual(TabTopEdgeKind.resolve(hasProgress: false, agentState: state, busy: false, hasLabel: true), .label)
            XCTAssertNil(TabTopEdgeKind.resolve(hasProgress: false, agentState: state, busy: false, hasLabel: false))
        }
    }

    func testTabsWithoutAnAgentKeepTheirTopEdgeOrder() {
        XCTAssertEqual(TabTopEdgeKind.resolve(hasProgress: true, agentState: nil, busy: true, hasLabel: true), .progress)
        XCTAssertEqual(TabTopEdgeKind.resolve(hasProgress: false, agentState: nil, busy: true, hasLabel: true), .busy)
        XCTAssertEqual(TabTopEdgeKind.resolve(hasProgress: false, agentState: nil, busy: false, hasLabel: true), .label)
    }
}
