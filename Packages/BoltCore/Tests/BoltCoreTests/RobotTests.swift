import Foundation
import XCTest
@testable import BoltCore

final class RobotTests: XCTestCase {
    // MARK: Payloads (quaddle_ble.py: text + "\n", binary bytes as-is)

    func testTextCommandsMatchTable() {
        XCTAssertEqual(RobotCommand.queryWiFi.payload, Data("w\n".utf8))
        XCTAssertEqual(RobotCommand.stand.payload, Data("kup\n".utf8))
        XCTAssertEqual(RobotCommand.rest.payload, Data("krest\n".utf8))
        XCTAssertEqual(RobotCommand.walkForward().payload, Data("kwkF 1\n".utf8))
        XCTAssertEqual(RobotCommand.walkBackward(cycles: 3).payload, Data("kwkB 3\n".utf8))
        XCTAssertEqual(RobotCommand.walkForward(cycles: 0).label, "kwkF 1")
    }

    func testBinaryIsRawPacket() {
        // quaddle_ble.py --binary 74 114 40 0 126
        XCTAssertEqual(RobotCommand.gaze(x: 40, y: 0).payload, Data([74, 114, 40, 0, 126]))
        // Signed bytes wrap like `v & 255`.
        XCTAssertEqual(RobotCommand.gaze(x: -1, y: -128), .binary([74, 114, 255, 128, 126]))
        XCTAssertEqual(RobotCommand.joints([(0, 30), (8, -15)]), .binary([73, 0, 30, 8, 241, 126]))
        XCTAssertEqual(RobotCommand.gaze(x: -1, y: 0).label, "binary 74 114 -1 0 126")
    }

    func testSpeechAndPromptMatchScript() {
        // quaddle_ble.py --say / --ask with the default Motion Core prefix ">> ".
        XCTAssertEqual(RobotCommand.say("Hello from Quaddle")?.payload, Data(#">> say "Hello from Quaddle"\#n"#.utf8))
        XCTAssertEqual(RobotCommand.ask("Hello, how are you?")?.payload, Data(">> Hello, how are you?\n".utf8))
        XCTAssertEqual(RobotCommand.flipRoll.payload, Data("kflipRoll\n".utf8))
        XCTAssertEqual(RobotCommand.say("Héllo 👋")?.payload, Data(#">> say "Héllo 👋"\#n"#.utf8))
    }

    func testSpeechAndPromptRejectUnsafeText() {
        for bad in ["", "   ", "two\nlines", "cr\rhere", "crlf\r\nhere", "nul\0here"] {
            XCTAssertNil(RobotCommand.say(bad), bad.debugDescription)
            XCTAssertNil(RobotCommand.ask(bad), bad.debugDescription)
        }
        XCTAssertNil(RobotCommand.say(#"she said "hi""#))
        XCTAssertNotNil(RobotCommand.ask(#"what does "hi" mean"#))   // quotes only matter inside say "…"
    }

    func testRobotNameMatch() {
        XCTAssertTrue(RobotUUIDs.isRobotName(RobotUUIDs.defaultName))
        XCTAssertTrue(RobotUUIDs.isRobotName("quaddle-2"))
        XCTAssertFalse(RobotUUIDs.isRobotName("Random Device 12"))
        XCTAssertFalse(RobotUUIDs.isRobotName(nil))
    }

    // MARK: Reply collection

    func testLinesSplitAcrossNotifications() {
        let t0 = Date(timeIntervalSince1970: 0)
        var c = RobotReplyCollector(sentAt: t0)
        c.add(Data("IP 10.1".utf8), at: t0.addingTimeInterval(0.1))
        c.add(Data(".2.3\r\nk".utf8), at: t0.addingTimeInterval(0.2))
        c.add(Data("up\n\n".utf8), at: t0.addingTimeInterval(0.3))
        XCTAssertEqual(c.lines, ["IP 10.1.2.3", "kup"])
        c.add(Data("trailing".utf8), at: t0.addingTimeInterval(0.4))
        XCTAssertEqual(c.allLines, ["IP 10.1.2.3", "kup", "trailing"])
    }

    func testDoneAfterQuietPeriod() {
        let t0 = Date(timeIntervalSince1970: 0)
        var c = RobotReplyCollector(sentAt: t0, quietSeconds: 1.5, listenSeconds: 8)
        XCTAssertFalse(c.isDone(at: t0.addingTimeInterval(3)))   // no reply yet: keep listening
        c.add(Data("k\n".utf8), at: t0.addingTimeInterval(3))
        XCTAssertFalse(c.isDone(at: t0.addingTimeInterval(4)))
        XCTAssertTrue(c.isDone(at: t0.addingTimeInterval(4.5)))
        XCTAssertTrue(c.gotReply)
    }

    func testDoneAtListenLimitWithoutReply() {
        let t0 = Date(timeIntervalSince1970: 0)
        let c = RobotReplyCollector(sentAt: t0, listenSeconds: 8)
        XCTAssertFalse(c.isDone(at: t0.addingTimeInterval(7.9)))
        XCTAssertTrue(c.isDone(at: t0.addingTimeInterval(8)))
        XCTAssertFalse(c.gotReply)
    }

    func testListenLimitWinsOverChattyRobot() {
        let t0 = Date(timeIntervalSince1970: 0)
        var c = RobotReplyCollector(sentAt: t0, quietSeconds: 1.5, listenSeconds: 8)
        for s in stride(from: 0.5, through: 7.5, by: 0.5) { c.add(Data("x\n".utf8), at: t0.addingTimeInterval(s)) }
        XCTAssertTrue(c.isDone(at: t0.addingTimeInterval(8)))
    }
}

final class RobotMoveTests: XCTestCase {
    func testDefaultsMatchConfirmedCommands() {
        let c = RobotMoveConfig.defaults
        XCTAssertEqual(c.stop, "kup")
        XCTAssertEqual(c.move(RobotMove.Key.wave)?.text, "khi")
        XCTAssertEqual(c.move(RobotMove.Key.doubleTap)?.text, "kflipRoll")
        XCTAssertEqual(c.move(RobotMove.Key.stand)?.text, "kup")
        XCTAssertEqual(c.move(RobotMove.Key.rest)?.text, "krest")
        let walk = c.move(RobotMove.Key.walkForward)
        XCTAssertEqual(walk?.text, "kstep1F")
        XCTAssertEqual(walk?.stopAfter, 3)
        XCTAssertEqual(Set(c.moves.map(\.id)), Set(RobotMove.Key.all))
    }

    func testContracts() {
        var m = RobotMove(title: "Walk", command: " kwkF ", contract: .steps, count: 3)
        XCTAssertEqual(m.robotCommand.payload, Data("kwkF 3\n".utf8))
        XCTAssertNil(m.stopAfter)
        m.count = 0
        XCTAssertEqual(m.text, "kwkF 1")
        m.contract = .timed; m.seconds = 2.5
        XCTAssertEqual(m.text, "kwkF")
        XCTAssertEqual(m.stopAfter, 2.5)
        XCTAssertEqual(m.summary(stop: "kup"), "kwkF · 2.5 s then kup")
        m.contract = .once
        XCTAssertNil(m.stopAfter)
        XCTAssertEqual(RobotMove(title: "Head", command: "m0 30").text, "m0 30")
    }

    func testSavedConfigRoundTripsAndRefillsBuiltIns() {
        var c = RobotMoveConfig.defaults
        c.stop = "d"
        c.moves[0].command = "kbalance"
        c.moves.removeAll { $0.id == RobotMove.Key.walkBack }
        c.moves.append(RobotMove(id: "x", title: "Dance", command: "kqDance"))
        let loaded = RobotMoveConfig.load(c.encoded())
        XCTAssertEqual(loaded.stop, "d")
        XCTAssertEqual(loaded.moves[0].command, "kbalance")
        XCTAssertEqual(loaded.move("x")?.command, "kqDance")
        XCTAssertEqual(loaded.move(RobotMove.Key.walkBack), RobotMoveConfig.defaults.move(RobotMove.Key.walkBack))
        XCTAssertEqual(RobotMoveConfig.load(Data("junk".utf8)), .defaults)
        XCTAssertEqual(RobotMoveConfig.load(nil), .defaults)
    }

    func testCatalogSplitsPairedCommands() {
        XCTAssertEqual(RobotCatalog.entry("kwkF")?.contract, .steps)
        XCTAssertEqual(RobotCatalog.entry("kvtR")?.contract, .timed)
        XCTAssertEqual(RobotCatalog.entry("kvtR")?.function, "Spin left / right")
        XCTAssertEqual(RobotCatalog.entry("kglide")?.contract, .once)
        XCTAssertNotNil(RobotCatalog.entry("vcv"))
        XCTAssertNotNil(RobotCatalog.entry("kpd2"))
        XCTAssertEqual(RobotCatalog.entry("khi")?.contract, .once)
        XCTAssertEqual(Set(RobotCatalog.all.map(\.command)).count, RobotCatalog.all.count)
    }
}
