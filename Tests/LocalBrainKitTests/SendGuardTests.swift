import XCTest
@testable import LocalBrainKit

final class SendGuardTests: XCTestCase {
    // MARK: - Labels

    func testTheBlockedLabelsAreRefused() {
        for label in ["Send", "send", "Send now", "Schedule send", "Send later", "Send and archive", "Discard",
                      "Discard draft", "Delete", "Archive", "Report spam", "Move to trash"] {
            XCTAssertFalse(SendGuard.mayPress(label: label), label)
        }
    }

    func testALabelThatStartsWithABlockedOneIsRefused() {
        for label in ["Send (⌘Enter)", "Send ⌘Enter", "Send message", "Delete forever", "Archive conversation",
                      "Discard draft and close", "Schedule send, tomorrow 8am"] {
            XCTAssertFalse(SendGuard.mayPress(label: label), label)
        }
    }

    func testBidiAndOtherInvisibleMarksDoNotHideASend() {
        XCTAssertFalse(SendGuard.mayPress(label: "\u{202A}Send\u{202C} (⌘Enter)"))
        XCTAssertFalse(SendGuard.mayPress(label: "Send \u{202A}(⌘Enter)\u{202C}"))
        XCTAssertFalse(SendGuard.mayPress(label: "\u{200E}Send\u{200F}"))
        XCTAssertFalse(SendGuard.mayPress(label: "\u{FEFF}S\u{200B}end"), "a zero width mark inside the word")
        XCTAssertFalse(SendGuard.mayPress(label: "  SEND  "))
        XCTAssertFalse(SendGuard.mayPress(label: "Send\u{00A0}now"))
    }

    func testNormalisationKeepsLettersAndDigitsOnly() {
        XCTAssertEqual(SendGuard.normalize("\u{202A}Send\u{202C} (⌘Enter)"), "send enter")
        XCTAssertEqual(SendGuard.normalize("  Move   to\ttrash! "), "move to trash")
        XCTAssertEqual(SendGuard.normalize(""), "")
    }

    func testHarmlessLabelsAreAllowed() {
        for label in ["Reply", "Reply all", "Compose", "Sender settings", "Sent", "Sent mail", "Sending options",
                      "Message Body", "Attach files", "Subject", "Draft saved", "Archived", "Deleted items", ""] {
            XCTAssertTrue(SendGuard.mayPress(label: label), label)
        }
    }

    // MARK: - The words

    func testClickingSendNeverBecomesAScreenClick() {
        for words in ["click send", "click on send", "click the send button", "press send", "press the send button",
                      "tap send", "hit send", "can you click send", "please click the send button",
                      "go ahead and click send", "select the send button", "double click send", "Click Send."] {
            XCTAssertTrue(SendGuard.clickTargetsSend(words), words)
        }
    }

    func testOtherClicksAreNotAboutSend() {
        for words in ["click the submit button", "press the save button", "click the sender name", "click on sent mail",
                      "draft an email saying i will send it tomorrow", "send me the file", "click the compose button"] {
            XCTAssertFalse(SendGuard.clickTargetsSend(words), words)
        }
    }

    func testTheRefusalIsShortAndPlain() {
        XCTAssertEqual(SendGuard.refusalLine, "press send yourself.")
    }

    // MARK: - No synthetic events in the action layer

    func testTheActionLayerPostsNoKeyOrMouseEvents() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent("Sources/LocalClickyActions")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "the scan must find the action layer's sources")
        let forbidden = ["CGEvent", "CGEventPost", "postToPid", "NSEvent.keyEvent", "NSEvent.mouseEvent", "CGPostKeyboardEvent",
                         "CGPostMouseEvent"]
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for token in forbidden {
                XCTAssertFalse(source.contains(token), "\(file.lastPathComponent) mentions \(token)")
            }
        }
    }

    func testNoPageWritePathSetsFocusOrRaisesAWindow() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Sources/LocalClickyActions"),
                                                                includingPropertiesForKeys: nil)
        files += ["DraftAgentRun.swift", "DraftRunPanel.swift"].map { root.appendingPathComponent("Sources/LocalClicky/Agent/\($0)") }
        let forbidden = ["AXRaise", "kAXFocusedAttribute", "\"AXFocused\"", "kAXFrontmostAttribute", "AXFrontmost", ".activate("]
        for file in files where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            for token in forbidden {
                XCTAssertFalse(source.contains(token), "\(file.lastPathComponent) mentions \(token)")
            }
        }
    }
}
