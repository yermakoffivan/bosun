import XCTest
@testable import BosunCore

final class PathCompletionTests: XCTestCase {
    private var root = ""

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "bosun-paths-\(UUID().uuidString)"
        let fm = FileManager.default
        for d in ["Projects/bosun", "Projects/bosun-old", "Projects/grav", "Projects/.hidden", "Projects/Beta", "work"] {
            try fm.createDirectory(atPath: "\(root)/\(d)", withIntermediateDirectories: true)
        }
        fm.createFile(atPath: "\(root)/Projects/bosun.txt", contents: Data())
        try fm.createSymbolicLink(atPath: "\(root)/Projects/linked", withDestinationPath: "\(root)/work")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func names(_ typed: String) -> [String] {
        PathCompletion.folders(matching: typed, home: root).map(\.name)
    }

    func testSplitsAtTheLastSlash() {
        XCTAssertEqual(PathCompletion.split("~/Projects/bo")?.dir, "~/Projects/")
        XCTAssertEqual(PathCompletion.split("~/Projects/bo")?.prefix, "bo")
        XCTAssertEqual(PathCompletion.split("/tmp/")?.prefix, "")
        XCTAssertEqual(PathCompletion.split("~")?.dir, "~/")
        XCTAssertNil(PathCompletion.split("Projects"))
        XCTAssertNil(PathCompletion.split("~andy/x"))
        XCTAssertNil(PathCompletion.split("rel/x"))
    }

    func testListsTheFoldersInADirectoryInFinderOrderWithoutFilesOrHiddenOnes() {
        XCTAssertEqual(names("~/Projects/"), ["Beta", "bosun", "bosun-old", "grav", "linked"])
        XCTAssertEqual(PathCompletion.folders(matching: "~/Projects/", home: root).first?.path, "~/Projects/Beta/")
        XCTAssertEqual(names("~"), ["Projects", "work"])
    }

    func testMatchesTheStartOfTheNameWhateverItsCase() {
        XCTAssertEqual(names("~/Projects/bo"), ["bosun", "bosun-old"])
        XCTAssertEqual(names("~/Projects/B"), ["Beta", "bosun", "bosun-old"])
        XCTAssertEqual(names("~/Projects/zz"), [])
    }

    func testHiddenFoldersOnceADotIsTyped() {
        XCTAssertEqual(names("~/Projects/."), [".hidden"])
    }

    func testAbsolutePathsAndUnreadableOnes() {
        XCTAssertEqual(PathCompletion.folders(matching: "\(root)/Projects/gr", home: "/nowhere").map(\.path), ["\(root)/Projects/grav/"])
        XCTAssertEqual(names("~/missing/"), [])
        XCTAssertEqual(names("Projects"), [])
    }

    func testLimit() {
        XCTAssertEqual(PathCompletion.folders(matching: "~/Projects/", home: root, limit: 2).map(\.name), ["Beta", "bosun"])
    }

    func testCompletion() {
        func complete(_ typed: String) -> String? {
            PathCompletion.completion(of: typed, entries: PathCompletion.folders(matching: typed, home: root))
        }
        // One match: the whole folder, with its slash.
        XCTAssertEqual(complete("~/Projects/gr"), "~/Projects/grav/")
        XCTAssertEqual(complete("~/Projects/GR"), "~/Projects/grav/")
        // Several: as far as they agree.
        XCTAssertEqual(complete("~/Projects/bo"), "~/Projects/bosun")
        // Already as far as they agree, or nothing matches: nothing to add.
        XCTAssertNil(complete("~/Projects/bosun"))
        XCTAssertNil(complete("~/Projects/"))
        XCTAssertNil(complete("~/Projects/zz"))
    }
}
