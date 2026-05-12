import Darwin
import XCTest
@testable import KakaoCore

/// Pure-logic tests for the multi-source process detection cascade in
/// `AppLifecycle`. The IO-bound queries (`NSRunningApplication`, `pgrep`) are
/// not exercised here — they live in private helpers and are tested by hand
/// on the Mac. What this suite locks in is the decision policy: which signal
/// wins, what "all negative" means, and which `DetectionSource` is reported.
final class AppLifecycleCascadeTests: XCTestCase {

    func testCascadePrefersNSRunningApp() {
        // NSRunningApp positive wins regardless of pgrep value.
        let result = AppLifecycle.cascadeWithSources(
            nsRunningPid: pid_t(1234),
            pgrepPid: pid_t(5678)
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.pid, 1234)
        XCTAssertEqual(result?.source, .nsRunningApp)
    }

    func testCascadeFallsBackToPgrepWhenNSRunningEmpty() {
        // NSRunningApp empty → pgrep is consulted and reported as the source.
        // This is the cross-session / Aqua-pin-missing rescue path.
        let result = AppLifecycle.cascadeWithSources(
            nsRunningPid: nil,
            pgrepPid: pid_t(5678)
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.pid, 5678)
        XCTAssertEqual(result?.source, .pgrep)
    }

    func testCascadeReturnsNilOnlyWhenAllSignalsAreNegative() {
        // Both sources negative — only then do we conclude not running.
        XCTAssertNil(AppLifecycle.cascadeWithSources(
            nsRunningPid: nil,
            pgrepPid: nil
        ))
    }

    func testCascadeIgnoresPgrepWhenNSRunningPresent() {
        // Equality / source identity check: even if pgrep would have
        // produced a *different* pid, NSRunningApp's pid is what we report
        // when both are positive. (Real-world they'd match; we still pin
        // the priority order in code.)
        let result = AppLifecycle.cascadeWithSources(
            nsRunningPid: pid_t(100),
            pgrepPid: pid_t(200)
        )
        XCTAssertEqual(result?.pid, 100)
        XCTAssertEqual(result?.source, .nsRunningApp)
    }
}
