import Foundation
import XCTest
@testable import TrellisCore

private struct InstalledFiles: LaunchFileAccess {
    let installed: Set<String>
    func isExecutableFile(_ path: String) -> Bool { installed.contains(path) }
    func isAccessibleDirectory(_ path: String) -> Bool { true }
}

final class ShellCatalogTests: XCTestCase {
    func testParseKeepsAbsolutePathsAndDropsComments() {
        let text = "# List of acceptable shells\n\n/bin/bash\n/bin/zsh # default\nrelative/sh\n  /usr/local/bin/fish  \n"
        XCTAssertEqual(ShellCatalog.parse(text), ["/bin/bash", "/bin/zsh", "/usr/local/bin/fish"])
    }

    func testOptionsAreInstalledDeduplicatedAndIncludeACustomCurrentShell() {
        let files = InstalledFiles(installed: ["/bin/bash", "/bin/zsh", "/bin/sh", "/opt/homebrew/bin/fish", "/Users/me/bin/nu"])
        let options = ShellCatalog.options(
            shellsFile: "/etc/shells", current: "/Users/me/bin/nu", files: files,
            read: { _ in "/bin/bash\n/bin/zsh\n/bin/sh\n/bin/ksh\n/bin/zsh\n" })
        XCTAssertEqual(options.map(\.path), ["/bin/bash", "/bin/zsh", "/bin/sh", "/opt/homebrew/bin/fish", "/Users/me/bin/nu"])
        XCTAssertEqual(options.map(\.integration), [.bash, .zsh, nil, .fish, nil])
        XCTAssertEqual(options.last?.name, "nu")
    }

    func testUnreadableShellsFileStillOffersInstalledShells() {
        let options = ShellCatalog.options(current: "/bin/zsh", files: InstalledFiles(installed: ["/bin/zsh"]), read: { _ in nil })
        XCTAssertEqual(options.map(\.path), ["/bin/zsh"])
    }
}
