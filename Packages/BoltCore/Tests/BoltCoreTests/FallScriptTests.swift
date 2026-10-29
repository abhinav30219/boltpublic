import XCTest
@testable import BoltCore

final class FallScriptTests: XCTestCase {
    let script = FallScript()
    let tuning = FallTuning()

    func testLinesWithName() {
        XCTAssertEqual(script.line(for: .asking, name: "Maya"), "Maya, are you okay? It looks like you fell. If you're okay, tap I'm okay on your phone.")
        XCTAssertEqual(script.line(for: .reasked, name: "Maya"), "Maya, are you okay? Tap I'm okay on your phone.")
        XCTAssertEqual(script.line(for: .alarm, name: "Maya"), "Help! Help! Maya has fallen! Please come and help!")
        XCTAssertEqual(script.line(for: .resolvedOK, name: "Maya"), "I'm glad you're okay. I'll keep an eye on you.")
    }

    func testLinesWithoutName() {
        for name in [nil, "", "   "] as [String?] {
            XCTAssertEqual(script.line(for: .asking, name: name), "Are you okay? It looks like you fell. If you're okay, tap I'm okay on your phone.")
            XCTAssertEqual(script.line(for: .reasked, name: name), "Are you okay? Tap I'm okay on your phone.")
            XCTAssertEqual(script.line(for: .alarm, name: name), "Help! Help! Someone has fallen! Please come and help!")
            XCTAssertEqual(script.line(for: .resolvedOK, name: name), "I'm glad you're okay. I'll keep an eye on you.")
        }
    }

    func testFirstNameOnlyAndTrimmed() {
        XCTAssertEqual(script.line(for: .reasked, name: "  Maya Rose Lee \n"), "Maya, are you okay? Tap I'm okay on your phone.")
    }

    func testQuotesInNamesAreSanitised() {
        for name in ["Ma\"ya", "\"Maya\"", "Ma\u{201C}ya\u{201D}", "Ma\nya", "\""] {
            for stage in [FallStage.asking, .reasked, .alarm, .resolvedOK] {
                let line = script.line(for: stage, name: name)
                XCTAssertFalse(line.contains("\""), line)
                XCTAssertFalse(line.contains("\u{201C}") || line.contains("\u{201D}"), line)
                XCTAssertFalse(line.contains("\n"), line)
            }
        }
        XCTAssertEqual(script.line(for: .alarm, name: "Ma\"ya"), "Help! Help! Maya has fallen! Please come and help!")
        // A name that is only a quote counts as no name.
        XCTAssertEqual(script.line(for: .alarm, name: "\""), "Help! Help! Someone has fallen! Please come and help!")
    }

    func testRobotSayAcceptsEveryLine() {
        for name in [nil, "Maya", "Ma\"ya", "O'Brien"] as [String?] {
            for stage in [FallStage.asking, .reasked, .alarm, .resolvedOK] {
                XCTAssertNotNil(RobotCommand.say(script.line(for: stage, name: name)), "\(stage) \(name ?? "nil")")
            }
        }
    }

    func testStageTransitions() {
        func s(_ t: Double) -> FallStage { script.stage(sinceAlert: t, helpRequested: false, resolved: false, tuning: tuning) }
        XCTAssertEqual(s(0), .asking)
        XCTAssertEqual(s(14.9), .asking)
        XCTAssertEqual(s(15), .reasked)
        XCTAssertEqual(s(29.9), .reasked)
        XCTAssertEqual(s(30), .alarm)
        XCTAssertEqual(s(600), .alarm)
    }

    func testStageHonoursTuning() {
        var t = FallTuning(); t.reaskSeconds = 5; t.responseTimeoutSeconds = 10
        XCTAssertEqual(script.stage(sinceAlert: 5, helpRequested: false, resolved: false, tuning: t), .reasked)
        XCTAssertEqual(script.stage(sinceAlert: 10, helpRequested: false, resolved: false, tuning: t), .alarm)
    }

    func testHelpRequestedGoesStraightToAlarm() {
        XCTAssertEqual(script.stage(sinceAlert: 0, helpRequested: true, resolved: false, tuning: tuning), .alarm)
        XCTAssertEqual(script.stage(sinceAlert: 3, helpRequested: true, resolved: false, tuning: tuning), .alarm)
    }

    func testResolvedOverridesEverything() {
        for t in [0.0, 16, 31, 500] {
            for help in [false, true] {
                XCTAssertEqual(script.stage(sinceAlert: t, helpRequested: help, resolved: true, tuning: tuning), .resolvedOK)
            }
        }
    }

    func testAlarmRepeatsEveryFiveSeconds() {
        XCTAssertFalse(script.alarmRepeatDue(secondsSinceLastLine: 0, tuning: tuning))
        XCTAssertFalse(script.alarmRepeatDue(secondsSinceLastLine: 4.9, tuning: tuning))
        XCTAssertTrue(script.alarmRepeatDue(secondsSinceLastLine: 5, tuning: tuning))
        // A 1 Hz loop from the alarm start repeats at 5, 10, 15 s.
        var last = 0.0, fired: [Int] = []
        for t in 1 ... 15 {
            if script.alarmRepeatDue(secondsSinceLastLine: Double(t) - last, tuning: tuning) { fired.append(t); last = Double(t) }
        }
        XCTAssertEqual(fired, [5, 10, 15])
    }

    func testTuningDefaultsAndDecoding() throws {
        XCTAssertEqual(tuning.reaskSeconds, 15)
        XCTAssertEqual(tuning.alarmRepeatSeconds, 5)
        let old = try JSONDecoder().decode(FallTuning.self, from: Data(#"{"responseTimeoutSeconds": 40}"#.utf8))
        XCTAssertEqual(old.reaskSeconds, 15)
        XCTAssertEqual(old.alarmRepeatSeconds, 5)
        XCTAssertEqual(old.responseTimeoutSeconds, 40)
        let new = try JSONDecoder().decode(FallTuning.self, from: Data(#"{"reaskSeconds": 8, "alarmRepeatSeconds": 3}"#.utf8))
        XCTAssertEqual(new.reaskSeconds, 8)
        XCTAssertEqual(new.alarmRepeatSeconds, 3)
    }

    func testWaveCooldownTuningDefault() throws {
        XCTAssertEqual(CompanionTuning().waveRobotCooldownSeconds, 10)
        let c = try JSONDecoder().decode(CompanionTuning.self, from: Data("{}".utf8))
        XCTAssertEqual(c.waveRobotCooldownSeconds, 10)
        let c2 = try JSONDecoder().decode(CompanionTuning.self, from: Data(#"{"waveRobotCooldownSeconds": 3}"#.utf8))
        XCTAssertEqual(c2.waveRobotCooldownSeconds, 3)
    }
}
