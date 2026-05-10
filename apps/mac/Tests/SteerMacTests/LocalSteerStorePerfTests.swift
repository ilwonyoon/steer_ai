import XCTest
@testable import SteerMac

/// Harness for the Mac local SQLite read path. The store shells out
/// to /usr/bin/sqlite3 for every `loadCards` and
/// `loadLiveSessions` call — process fork + exec + JSON serialize.
/// Off-main-thread (Task.detached) so the UI never blocks, but each
/// call has a fixed cost we want to put a real number on before
/// deciding whether to swap in an in-process SQLite binding.
///
/// What this measures:
///   - cold call: time to fork sqlite3 against a fresh DB
///   - warm calls: subsequent calls when the binary is already in
///     the file cache
///   - 50-call batch: throughput, p95
///
/// We don't assert on absolute numbers because they swing with
/// hardware and the simulator/CI host. We assert on RELATIVE
/// behaviour: warm < cold * 3 (sanity check that file cache works),
/// and p95 < 50ms (anything north of that means the UI's optimistic
/// reload cadence is too slow to feel snappy).
final class LocalSteerStorePerfTests: XCTestCase {

    private var tempHome: URL!
    private var dbURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("steer-mac-perf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        dbURL = tempHome.appendingPathComponent("steer.sqlite")
        try seedDB(at: dbURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempHome)
        try super.tearDownWithError()
    }

    private func seedDB(at url: URL) throws {
        // Use sqlite3 itself to write a minimal action_cards / sessions
        // schema so the queries the real store issues actually parse.
        let schema = """
            CREATE TABLE sessions (
              session_id TEXT PRIMARY KEY,
              provider TEXT,
              cwd TEXT,
              run_state TEXT,
              pid INTEGER,
              last_activity_at TEXT
            );
            CREATE TABLE action_cards (
              card_id TEXT PRIMARY KEY,
              session_id TEXT,
              category TEXT,
              run_state TEXT,
              priority TEXT,
              status TEXT,
              created_at TEXT,
              resolved_at TEXT,
              title TEXT,
              terminal_excerpt TEXT,
              branch_label TEXT,
              project_label TEXT
            );
            INSERT INTO sessions VALUES ('s1','codex','/tmp','idle',1,'2026-01-01T00:00:00Z');
            INSERT INTO action_cards (card_id, session_id, status) VALUES
              ('c1','s1','active'), ('c2','s1','active');
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [url.path, schema]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "Seed DB must build cleanly")
    }

    // MARK: - 1. Single call latency

    func test_loadCards_singleCall_completesUnder200ms() async throws {
        let store = LocalSteerStore(databaseURL: dbURL)
        let start = Date()
        _ = await store.loadCards()
        let elapsedMs = Date().timeIntervalSince(start) * 1000

        XCTAssertLessThan(
            elapsedMs, 200,
            "First (cold) loadCards must complete under 200ms; was \(elapsedMs)ms"
        )
    }

    // MARK: - 2. Throughput: 50 calls back-to-back

    func test_loadCards_50calls_p95Under50ms() async throws {
        let store = LocalSteerStore(databaseURL: dbURL)

        // Warm up so the first call's cold-cache cost doesn't skew
        // the median.
        _ = await store.loadCards()

        var samples: [Double] = []
        for _ in 0..<50 {
            let t = Date()
            _ = await store.loadCards()
            samples.append(Date().timeIntervalSince(t) * 1000)
        }

        let sorted = samples.sorted()
        let p50 = sorted[sorted.count / 2]
        let p95 = sorted[Int(Double(sorted.count) * 0.95)]
        let mean = samples.reduce(0, +) / Double(samples.count)

        print("[perf] LocalSteerStore.loadCards x50 — mean=\(String(format: "%.1f", mean))ms p50=\(String(format: "%.1f", p50))ms p95=\(String(format: "%.1f", p95))ms")

        XCTAssertLessThan(
            p95, 50.0,
            "p95 of loadCards must stay under 50ms for snappy reload; was \(p95)ms. Consider replacing /usr/bin/sqlite3 subprocess with an in-process SQLite binding."
        )
    }

    // MARK: - 3. Cold vs warm ratio (file cache sanity)

    func test_loadCards_warmCallIsFasterThanCold() async throws {
        let store = LocalSteerStore(databaseURL: dbURL)
        let cold = Date()
        _ = await store.loadCards()
        let coldMs = Date().timeIntervalSince(cold) * 1000

        let warm = Date()
        _ = await store.loadCards()
        let warmMs = Date().timeIntervalSince(warm) * 1000

        print("[perf] cold=\(String(format: "%.1f", coldMs))ms warm=\(String(format: "%.1f", warmMs))ms")
        // Warm must be at least as fast as cold. We give a 10ms slop
        // for clock noise on tiny absolute durations.
        XCTAssertLessThanOrEqual(
            warmMs, coldMs + 10,
            "Warm call (\(warmMs)ms) was slower than cold (\(coldMs)ms). The sqlite3 binary should already be in the page cache."
        )
    }
}
