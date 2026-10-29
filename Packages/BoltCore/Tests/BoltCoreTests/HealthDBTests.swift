import XCTest
@testable import BoltCore

final class HealthDBTests: XCTestCase {

    /// UTC+2 with no daylight saving, so day boundaries are fixed.
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 2 * 3600)!
        return c
    }()

    /// 2027-01-15 00:00 local (UTC+2).
    private var dayStart: Date { calendar.date(from: DateComponents(year: 2027, month: 1, day: 15))! }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("healthdb-\(UUID().uuidString)/health.sqlite")
    }

    private func window(at start: Date, steps: Int = 10, kcal: Double = 1, band: Int = 1, active: Bool = true,
                        label: FitnessLabel = .walk, hr: Double? = 80, hrv: Double? = 40) -> StoredWindow {
        StoredWindow(start: start.timeIntervalSince1970, end: start.timeIntervalSince1970 + 30, label: label, active: active,
                     steps: steps, cadence: 100, kcal: kcal, enmoMg: 60, intensityBand: band,
                     hrAvg: hr, hrMin: hr.map { $0 - 5 }, hrMax: hr.map { $0 + 5 }, hrv: hrv, spo2: 97, skinTemp: 33.5, worn: true)
    }

    func testProfileRoundTripsAndSurvivesReopen() throws {
        let url = tempURL()
        var p = UserProfile()
        p.name = "Ada"; p.age = 71; p.goals = ["Sleep better"]; p.notes = "knee"
        do {
            let db = try HealthDB(url: url, calendar: calendar)
            XCTAssertNil(db.loadProfile())
            db.saveProfile(p)
            db.markOnboarded(at: dayStart)
        }
        let db = try HealthDB(url: url, calendar: calendar)
        XCTAssertEqual(db.loadProfile(), p)
        XCTAssertEqual(db.onboardedAt, dayStart)
    }

    func testWindowWithSameStartReplacesTheOldOne() throws {
        let db = try HealthDB(url: nil, calendar: calendar)
        let t = dayStart.addingTimeInterval(9 * 3600)
        db.record(window: window(at: t, steps: 10))
        db.record(window: window(at: t, steps: 25))
        XCTAssertEqual(db.windowCount, 1)
        XCTAssertEqual(db.totals(on: t).steps, 25)
    }

    func testRelabelledWindowKeepsStoredVitals() throws {
        let db = try HealthDB(url: nil, calendar: calendar)
        let t = dayStart.addingTimeInterval(9 * 3600)
        db.record(window: window(at: t, steps: 10, label: .walk, hr: 90))
        db.record(windows: [window(at: t, steps: 0, active: false, label: .stationary, hr: nil, hrv: nil)])
        let s = db.summary(from: t, to: t + 30)
        XCTAssertEqual(s.totals.steps, 0)
        XCTAssertEqual(s.hrAvg!, 90, accuracy: 1e-9)
        XCTAssertEqual(s.hrv!, 40, accuracy: 1e-9)
    }

    func testWindowsReadBackOldestFirstAsIntervals() throws {
        let db = try HealthDB(url: nil, calendar: calendar)
        let t = dayStart.addingTimeInterval(9 * 3600)
        let a = window(at: t, steps: 12, kcal: 1.5, band: 2, label: .walk, hr: 92)
        let b = window(at: t + 30, steps: 0, active: false, label: .stationary, hr: nil)
        db.record(windows: [b, a])
        db.record(window: window(at: t + 3600))
        let got = db.windows(from: t, to: t + 60)
        XCTAssertEqual(got, [a, b])
        let i = got[0].interval
        XCTAssertEqual(i.start, a.start); XCTAssertEqual(i.end, a.end)
        XCTAssertEqual(i.label, .walk); XCTAssertTrue(i.active)
        XCTAssertEqual(i.metrics.steps, 12); XCTAssertEqual(i.metrics.band, 2)
        XCTAssertEqual(i.metrics.kcal, 1.5, accuracy: 1e-9)
        XCTAssertEqual(i.hr, 92, accuracy: 1e-9)
        XCTAssertEqual(got[1].interval.hr, 0)
    }

    func testTotalsMatchTimelineRules() throws {
        let db = try HealthDB(url: nil, calendar: calendar)
        let t = dayStart.addingTimeInterval(10 * 3600)
        db.record(window: window(at: t, steps: 10, kcal: 2, band: 1))
        db.record(window: window(at: t + 30, steps: 20, kcal: 3, band: 2))
        db.record(window: window(at: t + 60, steps: 5, kcal: 1, band: 3, active: false))
        db.record(window: window(at: t + 90, steps: 99, kcal: 9, band: 3, label: .sleeping))
        let totals = db.totals(on: t)
        XCTAssertEqual(totals.steps, 35)
        XCTAssertEqual(totals.activeKcal, 6, accuracy: 1e-9)
        XCTAssertEqual(totals.activeMinutes, 1.0)
        XCTAssertEqual(totals.mvpaMinutes, 1.0)
        XCTAssertEqual(totals.lightMinutes, 0.5)
        XCTAssertEqual(totals.mediumMinutes, 0.5)
        XCTAssertEqual(totals.highMinutes, 0.5)
    }

    func testDailySplitsOnLocalMidnight() throws {
        let db = try HealthDB(url: nil, calendar: calendar)
        // 23:59:00 and 23:59:30 on the 14th, 00:00:00 on the 15th (local).
        db.record(window: window(at: dayStart.addingTimeInterval(-60), steps: 7, hr: 60))
        db.record(window: window(at: dayStart.addingTimeInterval(-30), steps: 3, hr: 70))
        db.record(window: window(at: dayStart, steps: 11, hr: 90))
        let days = db.daily(from: dayStart.addingTimeInterval(-86400), to: dayStart)
        XCTAssertEqual(days.count, 2)
        XCTAssertEqual(days[0].start, dayStart.addingTimeInterval(-86400))
        XCTAssertEqual(days[0].totals.steps, 10)
        XCTAssertEqual(days[0].windows, 2)
        XCTAssertEqual(days[0].hrAvg!, 65, accuracy: 1e-9)
        XCTAssertEqual(days[0].hrMin!, 55, accuracy: 1e-9)
        XCTAssertEqual(days[0].hrMax!, 75, accuracy: 1e-9)
        XCTAssertEqual(days[0].wornMinutes, 1.0)
        XCTAssertEqual(days[1].start, dayStart)
        XCTAssertEqual(days[1].totals.steps, 11)
    }

    func testHourlyHasOneEntryPerHourAndEmptyHoursHaveNoVitals() throws {
        let db = try HealthDB(url: nil, calendar: calendar)
        db.record(window: window(at: dayStart.addingTimeInterval(8 * 3600 + 600), steps: 4))
        db.record(window: window(at: dayStart.addingTimeInterval(8 * 3600 + 3000), steps: 6))
        db.record(window: window(at: dayStart.addingTimeInterval(13 * 3600), steps: 1, hr: nil, hrv: nil))
        let hours = db.hourly(on: dayStart.addingTimeInterval(12 * 3600))
        XCTAssertEqual(hours.count, 24)
        XCTAssertEqual(hours[8].totals.steps, 10)
        XCTAssertEqual(hours[13].totals.steps, 1)
        XCTAssertNil(hours[13].hrAvg)
        XCTAssertEqual(hours[0].windows, 0)
        XCTAssertNil(hours[0].hrAvg)
    }

    func testLatestBaselineIsTheNewest() throws {
        let db = try HealthDB(url: nil, calendar: calendar)
        XCTAssertNil(db.latestBaseline())
        db.recordBaseline(Baseline(heartRate: 66, hrv: 42, skinTemp: 33, establishedAt: dayStart), at: dayStart)
        db.recordBaseline(Baseline(heartRate: 64, hrv: 45, skinTemp: nil, establishedAt: dayStart), at: dayStart + 600)
        XCTAssertEqual(db.latestBaseline(), Baseline(heartRate: 64, hrv: 45, skinTemp: nil, establishedAt: dayStart))
    }

    func testCardsSaveLoadNewestFirstAndDelete() throws {
        let db = try HealthDB(url: nil, calendar: calendar)
        let a = InsightCard(event: InsightEvent(kind: .exertion, createdAt: dayStart, facts: [.num("Heart rate", 120, "bpm")]),
                            text: "Working hard.", source: .gemma, isStreaming: false)
        let b = InsightCard(event: InsightEvent(kind: .recovery, createdAt: dayStart + 60, facts: []),
                            text: "Coming down.", source: .template, isStreaming: false)
        db.save(card: a); db.save(card: b); db.save(card: b)
        XCTAssertEqual(db.recentCards(limit: 10), [b, a])
        XCTAssertEqual(db.recentCards(limit: 1), [b])
        db.deleteCards()
        XCTAssertEqual(db.recentCards(limit: 10), [])
    }

    func testWipeLeavesAnEmptyUsableDatabase() throws {
        let url = tempURL()
        let db = try HealthDB(url: url, calendar: calendar)
        var p = UserProfile(); p.name = "Ada"
        db.saveProfile(p)
        db.record(window: window(at: dayStart))
        db.wipe()
        XCTAssertNil(db.loadProfile())
        XCTAssertEqual(db.windowCount, 0)
        db.record(window: window(at: dayStart))
        XCTAssertEqual(db.windowCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testReopenKeepsSchemaVersionAndDayCount() throws {
        let url = tempURL()
        do {
            let db = try HealthDB(url: url, calendar: calendar)
            db.record(window: window(at: dayStart))
            db.record(window: window(at: dayStart.addingTimeInterval(86400 * 3)))
        }
        let db = try HealthDB(url: url, calendar: calendar)
        XCTAssertEqual(db.schemaVersion, HealthDB.currentVersion)
        XCTAssertEqual(db.dayCount, 2)
        XCTAssertGreaterThan(db.fileSize, 0)
    }
}
