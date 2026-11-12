import Foundation
import TrellisCore
import XCTest

@testable import TrellisControl

/// A project as JSON (FR-PL03, FR-PL04): strict, located problems, a stable encoding.
final class ProjectJSONTests: XCTestCase {
    private let text = """
        {
          "name": "Shop",
          "notes": "Checkout service",
          "repository": {
            "url": "git@github.com:acme/shop.git"
          },
          "tabs": [
            {
              "title": "API",
              "color": "green",
              "root": {
                "type": "split",
                "axis": "x",
                "ratio": 0.6,
                "children": [
                  {
                    "type": "pane",
                    "title": "Server",
                    "directory": "api",
                    "command": "make dev",
                    "repository": {
                      "url": "https://github.com/acme/api.git",
                      "branch": "main"
                    }
                  },
                  {
                    "type": "pane"
                  }
                ]
              }
            },
            {
              "title": "Web",
              "directory": "web",
              "repository": {
                "url": "git@github.com:acme/web.git"
              },
              "root": {
                "type": "pane",
                "command": "npm run dev"
              }
            }
          ]
        }

        """

    func testAProjectRoundTripsToTheSameBytes() throws {
        let project = try ProjectJSON.parse(Data(text.utf8)).get()
        XCTAssertEqual(project.checkouts.map(\.folder), ["", "api", "web"])
        XCTAssertEqual(String(decoding: ProjectJSON.encode(project), as: UTF8.self), text)
    }

    /// FR-PL10: an agent pane survives the JSON form (it used to be refused as an unknown field, and dropped on export).
    func testAnAgentPaneRoundTrips() throws {
        let json = #"{"name":"P","tabs":[{"title":"T","root":{"type":"split","axis":"x","children":[{"type":"pane","title":"Codex","agent":"trellis-codex"},{"type":"pane"}]}}]}"#
        let project = try ProjectJSON.parse(Data(json.utf8)).get()
        XCTAssertEqual(project.agentCount, 1)
        let again = try ProjectJSON.parse(ProjectJSON.encode(project)).get()
        XCTAssertEqual(again.tabs.first?.root.panes.first?.pane.agent, "trellis-codex")
        XCTAssertEqual(again.tabs, project.tabs)
        XCTAssertNotNil(String(decoding: ProjectJSON.encode(project), as: UTF8.self).range(of: #""title": "Codex",\n\s*"agent": "trellis-codex""#, options: .regularExpression))
    }

    func testUnknownFieldsAndRuleBreaksAreReportedWithTheirPlace() {
        func problems(_ json: String) -> [String] {
            guard case .failure(let error) = ProjectJSON.parse(Data(json.utf8)) else { return [] }
            return error.problems
        }
        XCTAssertEqual(problems(#"{"name":"P","tabs":[{"title":"T","root":{"type":"pane"}}],"version":1}"#), ["The project: has unsupported fields: version."])
        XCTAssertEqual(problems(#"{"name":"P","tabs":[{"title":"T","root":{"type":"pane","cmd":"x"}}]}"#), ["Tab 1 layout: has unsupported fields: cmd."])
        let unsafe = problems(#"{"name":"P","tabs":[{"title":"T","root":{"type":"pane","directory":"../etc","repository":{"url":"ext::sh"}}}]}"#)
        XCTAssertEqual(unsafe.count, 2, "\(unsafe)")
        XCTAssertTrue(unsafe.allSatisfy { $0.hasPrefix("Tab 1 “T”, pane 1:") }, "\(unsafe)")
        XCTAssertEqual(problems("not json"), ["The text is not valid JSON."])
    }
}
