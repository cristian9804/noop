import XCTest
@testable import StrandImport

final class WhoopExportImporterTests: XCTestCase {

    // MARK: - Header normalization

    func testHeaderNormalization() {
        XCTAssertEqual(HeaderNorm.normalize("Heart rate variability (ms)"), "heart_rate_variability_ms")
        XCTAssertEqual(HeaderNorm.normalize("Recovery score %"), "recovery_score_pct")
        XCTAssertEqual(HeaderNorm.normalize("In bed duration (min)"), "in_bed_duration_min")
        XCTAssertEqual(HeaderNorm.normalize("  Cycle start time  "), "cycle_start_time")
        XCTAssertEqual(HeaderNorm.normalize("HR Zone 1 %"), "hr_zone_1_pct")
    }

    // MARK: - BOM stripping

    func testBOMIsStripped() {
        let raw = Fixtures.data("physiological_cycles.csv")
        // Confirm the fixture actually carries a UTF-8 BOM.
        XCTAssertGreaterThanOrEqual(raw.count, 3)
        XCTAssertEqual(Array(raw.prefix(3)), [0xEF, 0xBB, 0xBF])

        let table = CSVTable(data: raw)
        // After stripping, the first header must normalize to cycle_start_time,
        // not "\u{FEFF}cycle_start_time".
        XCTAssertTrue(table.normalizedHeaders.contains("cycle_start_time"))
        XCTAssertFalse(table.normalizedHeaders.first?.contains("\u{FEFF}") ?? false)
    }

    // MARK: - Timezone parsing

    func testTimezoneOffsetParsing() {
        XCTAssertEqual(WhoopTime.tzOffsetMinutes("UTC+01:00"), 60)
        XCTAssertEqual(WhoopTime.tzOffsetMinutes("UTC-05:00"), -300)
        XCTAssertEqual(WhoopTime.tzOffsetMinutes("+02:30"), 150)
        XCTAssertEqual(WhoopTime.tzOffsetMinutes("UTC"), 0)
        XCTAssertEqual(WhoopTime.tzOffsetMinutes("Z"), 0)
        XCTAssertEqual(WhoopTime.tzOffsetMinutes(nil), 0)
        XCTAssertEqual(WhoopTime.tzOffsetMinutes("UTC+0530"), 330)
    }

    func testTimestampParsedInGivenOffsetToUTC() {
        // 06:30 at UTC+01:00 == 05:30 UTC.
        let d = WhoopTime.parse("2024-01-02 06:30:00", offsetMinutes: 60)
        XCTAssertEqual(d, Fixtures.utc(2024, 1, 2, 5, 30, 0))

        // 00:05 at UTC-05:00 == 05:05 UTC.
        let d2 = WhoopTime.parse("2024-01-03 00:05:00", offsetMinutes: -300)
        XCTAssertEqual(d2, Fixtures.utc(2024, 1, 3, 5, 5, 0))
    }

    // MARK: - physiological_cycles.csv

    func testCyclesParseToExpectedValues() throws {
        let table = CSVTable(data: Fixtures.data("physiological_cycles.csv"))
        let rows = WhoopExportImporter().parseCycles(table)

        XCTAssertEqual(rows.count, 2)
        let r0 = rows[0]

        // Cycle start: 2024-01-02 06:30:00 at UTC+01:00 -> 05:30 UTC.
        XCTAssertEqual(r0.cycleStart, Fixtures.utc(2024, 1, 2, 5, 30, 0))
        XCTAssertEqual(r0.tzOffsetMin, 60)
        XCTAssertEqual(r0.recoveryScore, 72)
        XCTAssertEqual(r0.restingHeartRate, 52)
        XCTAssertEqual(r0.hrvMs, 68.4)
        XCTAssertEqual(r0.skinTempCelsius, 33.1)
        XCTAssertEqual(r0.bloodOxygenPct, 96.0)
        XCTAssertEqual(r0.dayStrain, 12.5)
        XCTAssertEqual(r0.energyKcal, 2450)        // "(cal)" treated as kcal, not converted
        XCTAssertEqual(r0.maxHeartRate, 165)
        XCTAssertEqual(r0.avgHeartRate, 68)
        XCTAssertEqual(r0.sleepPerformancePct, 85)
        XCTAssertEqual(r0.respiratoryRate, 14.2)
        XCTAssertEqual(r0.asleepDurationMin, 420)   // kept in minutes
        XCTAssertEqual(r0.inBedDurationMin, 455)
        XCTAssertEqual(r0.lightSleepDurationMin, 210)
        XCTAssertEqual(r0.deepSleepDurationMin, 95)
        XCTAssertEqual(r0.remDurationMin, 115)
        XCTAssertEqual(r0.awakeDurationMin, 35)
        XCTAssertEqual(r0.sleepEfficiencyPct, 92.3)
        XCTAssertEqual(r0.sleepConsistencyPct, 88.0)
        XCTAssertEqual(r0.sleepNeedMin, 480)
        XCTAssertEqual(r0.sleepDebtMin, 60)

        // Sleep onset 2024-01-01 23:15 at +01:00 -> 22:15 UTC.
        XCTAssertEqual(r0.sleepOnset, Fixtures.utc(2024, 1, 1, 22, 15, 0))

        // Second row uses a negative offset.
        let r1 = rows[1]
        XCTAssertEqual(r1.tzOffsetMin, -300)
        XCTAssertEqual(r1.cycleStart, Fixtures.utc(2024, 1, 3, 11, 29, 0)) // 06:29 -05:00
        XCTAssertEqual(r1.recoveryScore, 55)
    }

    // MARK: - workouts.csv WITHOUT GPS columns

    func testWorkoutsWithoutGPSColumnsStillParse() throws {
        let table = CSVTable(data: Fixtures.data("workouts.csv"))
        let rows = WhoopExportImporter().parseWorkouts(table)

        XCTAssertEqual(rows.count, 2)
        let w0 = rows[0]
        XCTAssertEqual(w0.activityName, "Running")
        XCTAssertEqual(w0.activityStrain, 11.2)
        XCTAssertEqual(w0.energyKcal, 540)
        XCTAssertEqual(w0.maxHeartRate, 182)
        XCTAssertEqual(w0.avgHeartRate, 158)
        XCTAssertEqual(w0.hrZone3Pct, 40.0)
        XCTAssertEqual(w0.workoutStart, Fixtures.utc(2024, 1, 2, 17, 0, 0)) // +00:00

        // GPS / distance / altitude columns are absent → nil, not an error.
        XCTAssertNil(w0.distanceMeters)
        XCTAssertNil(w0.altitudeGainMeters)
        XCTAssertNil(w0.altitudeChangeMeters)
    }

    // MARK: - workouts.csv WITH GPS columns (synthetic, in-memory)

    func testWorkoutsWithGPSColumnsParse() throws {
        let csv = """
        Workout start time,Cycle timezone,Activity name,Distance (meters),Altitude gain (meters),Altitude change (meters)
        2024-02-01 09:00:00,UTC+00:00,Cycling,15230.5,210.0,-5.0
        """
        let rows = WhoopExportImporter().parseWorkouts(CSVTable(text: csv))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].activityName, "Cycling")
        XCTAssertEqual(rows[0].distanceMeters, 15230.5)
        XCTAssertEqual(rows[0].altitudeGainMeters, 210.0)
        XCTAssertEqual(rows[0].altitudeChangeMeters, -5.0)
    }

    // MARK: - sleeps.csv with Nap column

    func testSleepsNapColumn() throws {
        let table = CSVTable(data: Fixtures.data("sleeps.csv"))
        let rows = WhoopExportImporter().parseSleeps(table)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].isNap, false)
        XCTAssertEqual(rows[1].isNap, true)
        XCTAssertEqual(rows[0].sleepPerformancePct, 85)
        // Nap row has blank optional cells -> nil, not crash.
        XCTAssertNil(rows[1].sleepPerformancePct)
        XCTAssertEqual(rows[1].asleepDurationMin, 25)
    }

    // MARK: - journal_entries.csv

    func testJournalPivot() throws {
        let table = CSVTable(data: Fixtures.data("journal_entries.csv"))
        let rows = WhoopExportImporter().parseJournal(table)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].question, "Did you drink any alcohol?")
        XCTAssertEqual(rows[0].answer, "false")
        XCTAssertNil(rows[0].notes)
        XCTAssertEqual(rows[1].question, "Did you have any caffeine?")
        XCTAssertEqual(rows[1].answer, "true")
        XCTAssertEqual(rows[1].notes, "One coffee in the morning")
    }

    // MARK: - Folder import end to end

    func testImportFromFolder() throws {
        // The Resources directory itself is a folder containing all the CSVs.
        let folder = Fixtures.url("physiological_cycles.csv").deletingLastPathComponent()
        let result = try WhoopExportImporter().import(from: folder)

        XCTAssertEqual(result.cycles.count, 2)
        XCTAssertEqual(result.sleeps.count, 2)
        XCTAssertEqual(result.workouts.count, 2)
        XCTAssertEqual(result.journal.count, 2)

        XCTAssertEqual(result.summary.sourceKind, .whoopExport)
        XCTAssertEqual(result.summary.recordCount, 8)
        XCTAssertEqual(result.summary.countsByCategory["cycles"], 2)
        XCTAssertEqual(result.summary.countsByCategory["workouts"], 2)
        XCTAssertNotNil(result.summary.earliest)
        XCTAssertNotNil(result.summary.latest)
        XCTAssertLessThanOrEqual(result.summary.earliest!, result.summary.latest!)
    }

    // MARK: - Robustness: extra/unknown columns, reordered headers

    func testExtraAndReorderedColumnsTolerated() throws {
        let csv = """
        Some Future Column,Cycle timezone,Recovery score %,Cycle start time,Another Unknown
        hello,UTC+00:00,80,2024-03-01 06:00:00,world
        """
        let rows = WhoopExportImporter().parseCycles(CSVTable(text: csv))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].recoveryScore, 80)
        XCTAssertEqual(rows[0].cycleStart, Fixtures.utc(2024, 3, 1, 6, 0, 0))
    }

    // MARK: - CSV quoting

    func testQuotedFieldsWithCommasAndQuotes() {
        let csv = "a,b,c\n\"hello, world\",\"she said \"\"hi\"\"\",plain\n"
        let table = CSVTable(text: csv)
        XCTAssertEqual(table.rows.count, 1)
        XCTAssertEqual(table.rows[0]["a"], "hello, world")
        XCTAssertEqual(table.rows[0]["b"], "she said \"hi\"")
        XCTAssertEqual(table.rows[0]["c"], "plain")
    }
}
