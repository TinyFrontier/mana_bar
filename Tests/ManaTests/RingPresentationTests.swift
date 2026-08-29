import XCTest
@testable import Mana

/// Coverage for the pure presentation decisions `RingView` and
/// `DetailCardView` delegate to: what a ring draws for each `ServiceStatus`
/// (`RingPresentation`) and which wording a `UsageError` gets
/// (`UsageErrorCopy`).
final class RingPresentationTests: XCTestCase {
    private func usage(percent: Double) -> ServiceUsage {
        ServiceUsage(
            serviceID: .claude,
            plan: nil,
            windows: [
                UsageWindow(kind: .session, label: "Session", usedPercent: percent, resetsAt: nil, periodDuration: 5 * 3600),
            ],
            refreshedAt: Date(timeIntervalSince1970: 1_800_000_000),
            warning: nil
        )
    }

    // MARK: - .ready

    func testReadyShowsLivePercentWithLevelColorAndNoBadge() {
        let presentation = RingPresentation.make(status: .ready(usage(percent: 73)))

        XCTAssertEqual(presentation.label, "73%")
        XCTAssertEqual(presentation.fillFraction, 0.73, accuracy: 0.0001)
        XCTAssertFalse(presentation.isMuted)
        XCTAssertFalse(presentation.usesNeutralColor)
        XCTAssertFalse(presentation.showsErrorBadge)
        XCTAssertFalse(presentation.showsSpinner)
    }

    // MARK: - .stale (the live-feedback bug this suite exists for)

    /// Regression: a `.stale` service (last-good data + a fetch error) used to
    /// be lumped in with `.unavailable` — the ring emptied out to 0 fill and
    /// its label became "—", even though the detail card was showing the very
    /// numbers the ring had just thrown away. The numbers stay; only the
    /// styling says "not live", and the "!" badge stays to say so too.
    func testStaleKeepsLastKnownPercentMutedWithErrorBadge() {
        let presentation = RingPresentation.make(status: .stale(usage(percent: 73), .connectionFailed))

        XCTAssertEqual(presentation.label, "73%", "a stale ring must keep showing the last known percentage")
        XCTAssertEqual(presentation.fillFraction, 0.73, accuracy: 0.0001, "a stale ring must keep its last known fill")
        XCTAssertTrue(presentation.isMuted, "stale data must read as not-live")
        XCTAssertFalse(presentation.usesNeutralColor, "the usage level is still known, so the ring keeps its level color")
        XCTAssertTrue(presentation.showsErrorBadge)
        XCTAssertEqual(presentation.percent, 73)
    }

    func testStalePercentIsRoundedAndClampedLikeReady() {
        XCTAssertEqual(RingPresentation.make(status: .stale(usage(percent: 0), .sessionExpired)).label, "0%")
        XCTAssertEqual(RingPresentation.make(status: .stale(usage(percent: 99.6), .sessionExpired)).label, "100%")
        XCTAssertEqual(
            RingPresentation.make(status: .stale(usage(percent: 140), .sessionExpired)).fillFraction,
            1,
            "fill is clamped to the ring's circumference even if the API over-reports"
        )
    }

    func testStaleShowsSpinnerWhileRefreshing() {
        let presentation = RingPresentation.make(
            status: .stale(usage(percent: 40), .connectionFailed),
            isRefreshing: true
        )

        XCTAssertTrue(presentation.showsSpinner, "an in-flight retry must be visible on top of the stale ring")
        XCTAssertEqual(presentation.label, "40%", "the spinner must never replace the data")
    }

    // MARK: - .unavailable / .loading (unchanged behavior)

    func testUnavailableShowsDashOnNeutralEmptyRingWithBadge() {
        let presentation = RingPresentation.make(status: .unavailable(.notLoggedIn))

        XCTAssertEqual(presentation.label, "—")
        XCTAssertEqual(presentation.fillFraction, 0)
        XCTAssertTrue(presentation.isMuted)
        XCTAssertTrue(presentation.usesNeutralColor)
        XCTAssertTrue(presentation.showsErrorBadge)
    }

    func testLoadingShowsEllipsisSpinnerAndNoBadge() {
        let presentation = RingPresentation.make(status: .loading)

        XCTAssertEqual(presentation.label, "···")
        XCTAssertEqual(presentation.fillFraction, 0)
        XCTAssertTrue(presentation.showsSpinner)
        XCTAssertFalse(presentation.showsErrorBadge)
    }

    /// A service whose windows the API didn't report can't show a number even
    /// though the status is `.ready` — it must not claim "0%" of nothing.
    func testReadyWithoutASessionWindowFallsBackToZero() {
        let noWindows = ServiceUsage(
            serviceID: .chatgpt,
            plan: nil,
            windows: [],
            refreshedAt: Date(timeIntervalSince1970: 1_800_000_000),
            warning: nil
        )
        let presentation = RingPresentation.make(status: .ready(noWindows))

        XCTAssertEqual(presentation.fillFraction, 0)
        XCTAssertEqual(presentation.label, "0%")
    }

    // MARK: - UsageErrorCopy (timeout vs offline)

    /// `.connectionFailed` covers both "this machine is offline" and "the
    /// request ran out of time". Telling a user with a working browser "Нет
    /// соединения" is a lie they can immediately disprove.
    func testTimedOutConnectionFailureGetsItsOwnWording() {
        XCTAssertEqual(
            UsageErrorCopy.text(for: .connectionFailed, timedOut: true),
            "Сервис не отвечает"
        )
        XCTAssertEqual(
            UsageErrorCopy.text(for: .connectionFailed, timedOut: false),
            UsageError.connectionFailed.userDescription
        )
    }

    /// The timeout flag is only ever meaningful for `.connectionFailed`; every
    /// other case keeps the frozen contract's own wording verbatim.
    func testTimedOutFlagNeverRewritesOtherErrors() {
        let others: [UsageError] = [
            .notLoggedIn,
            .keychainAccessDenied,
            .sessionExpired,
            .missingScope,
            .rateLimited(retryAfter: 30),
            .requestFailed(statusCode: 503),
            .decodingFailed("nope"),
        ]
        for error in others {
            XCTAssertEqual(
                UsageErrorCopy.text(for: error, timedOut: true),
                error.userDescription,
                "\(error) must keep its frozen-contract wording"
            )
        }
    }
}
