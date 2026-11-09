import DiscordTestSupport
import DiscordTransport
import Foundation
import Testing
@testable import DiscordHTTP

/// Direct virtual-time regressions for alias discovery, elapsed windows and nonrefundable rate ownership.
/// No scheduler, network, wall clock, background task or production credential participates in these tests.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
@Suite struct MC29RateAccountingTests {
    /// One explicitly controlled monotonic time domain, shared by every call within a scenario.
    private typealias Instant = ManualClock.Instant
    /// Actual in-process authority rather than a model or forwarding implementation.
    private typealias Store = InProcessRateLimitStore<Instant>
    /// Exact ownership returned by the authority, retained until one completion or release.
    private typealias Reservation = RateLimitReservation<Instant>

    /// Three independently admitted cold routes learn one bucket without importing their depleted startup guards.
    /// Reversed completion retains the lowest server headroom without charging an acknowledged alias twice.
    /// - Parameter order: A deterministic completion permutation for the same three server observations.
    /// - Throws: Unexpected authority errors or a missing required admission.
    @Test(arguments: [[0, 1, 2], [2, 1, 0], [1, 0, 2]])
    func positiveHeadroomSurvivesABCDiscovery(order: [Int]) async throws {
        let store = makeStore(), now = Instant(), identity = RateLimitIdentity()
        let requests = (0..<3).map { request(identity, route: "GET /alias/\($0)") }
        var tokens: [Reservation] = []
        for item in requests { tokens.append(try await admit(store, item, at: now)) }
        for index in order {
            try await store.complete(tokens[index], status: 200,
                headers: headers(remaining: 9 - index), now: now)
        }
        try await consume(store, requests[0], count: 7, at: now)
        for item in requests { try await blocked(store, item, at: now, until: now.advanced(by: .seconds(10))) }
        let snapshot = await store.snapshot()
        #expect(snapshot.activeCount == 0 && snapshot.metadataCount == 4)
    }

    /// Pending known-bucket sends and reversed responses cannot refund an already debited allowance.
    /// A lower late observation may conservatively reduce headroom because external sends cannot be excluded.
    /// - Throws: Unexpected authority errors or a missing required admission.
    @Test func overlappingReversedCompletionsRetainEveryDebit() async throws {
        let store = makeStore(), now = Instant(), item = request(.init(), route: "GET /overlap")
        let prime = try await admit(store, item, at: now)
        try await store.complete(prime, status: 200, headers: headers(limit: 6, remaining: 5), now: now)
        var tokens: [Reservation] = []
        for _ in 0..<3 { tokens.append(try await admit(store, item, at: now)) }
        for (index, remaining) in [(2, 2), (1, 3), (0, 4)] {
            try await store.complete(tokens[index], status: 200,
                headers: headers(limit: 6, remaining: remaining), now: now)
        }
        try await blocked(store, item, at: now, until: now.advanced(by: .seconds(10)))
        #expect(await store.snapshot().activeCount == 0)
    }

    /// A hash migration transfers all aliases and unknown sends, retaining both learned allowance floors.
    /// Releasing the other outstanding send clears ownership without refunding its transferred debit.
    /// - Throws: Unexpected authority errors or a missing required admission.
    @Test func migrationMovesAliasesAndUnrepresentedSendOnce() async throws {
        let store = makeStore(), now = Instant(), identity = RateLimitIdentity()
        let a = request(identity, route: "GET /migration/a"), b = request(identity, route: "GET /migration/b")
        let c = request(identity, route: "GET /migration/c")
        let first = try await admit(store, a, at: now)
        try await store.complete(first, status: 200, headers: headers(bucket: "old", remaining: 9), now: now)
        let sibling = try await admit(store, c, at: now)
        try await store.complete(sibling, status: 200, headers: headers(bucket: "old", remaining: 8), now: now)
        let migrating = try await admit(store, a, at: now)
        let uncertain = try await admit(store, c, at: now)
        let destination = try await admit(store, b, at: now)
        try await store.complete(destination, status: 200, headers: headers(bucket: "new", remaining: 7), now: now)
        try await store.complete(migrating, status: 200, headers: headers(bucket: "new", remaining: 8), now: now)
        try await store.release(uncertain, outcome: .uncertain, now: now)
        try await consume(store, c, count: 6, at: now)
        for item in [a, b, c] { try await blocked(store, item, at: now, until: now.advanced(by: .seconds(10))) }
        let snapshot = await store.snapshot()
        #expect(snapshot.activeCount == 0 && snapshot.metadataCount == 4)
    }

    /// An observation just before a known reset cannot refund exhaustion; exact/late reset observations first replenish safely.
    /// The outstanding old send is reserved in the new window before its own current observation is accepted.
    /// - Parameter offset: Explicit response time around the one-hundred-millisecond known boundary.
    /// - Throws: Unexpected authority errors or a missing required admission.
    @Test(arguments: [Duration.milliseconds(99), .milliseconds(100), .milliseconds(101)])
    func completionCrossingResetRollsBeforeLearning(offset: Duration) async throws {
        let store = makeStore(), now = Instant(), item = request(.init(), route: "GET /cross-reset")
        let first = try await admit(store, item, at: now)
        try await store.complete(first, status: 200, headers: headers(limit: 5, remaining: 1, reset: "0.1"), now: now)
        let crossing = try await admit(store, item, at: now)
        let observed = now.advanced(by: offset)
        try await store.complete(crossing, status: 200,
            headers: headers(limit: 5, remaining: 4, reset: offset < .milliseconds(100) ? "0.001" : "0.1"), now: observed)
        if offset < .milliseconds(100) {
            try await blocked(store, item, at: observed, until: now.advanced(by: .milliseconds(100)))
        } else {
            try await consume(store, item, count: 4, at: observed)
            try await blocked(store, item, at: observed, until: observed.advanced(by: .milliseconds(100)))
        }
        #expect(await store.snapshot().activeCount == 0)
    }

    /// A reservation's admission epoch cannot authenticate the server window of its delayed response.
    /// New-window admission already carries old owners, and delayed headers can only lower its learned floor.
    /// - Parameter remaining: Missing, depleted, plausible or stale-high remaining metadata from the older send.
    /// - Throws: Unexpected authority errors or a missing required admission.
    @Test(arguments: [nil, "0", "4", "99"] as [String?])
    func oldResponseAfterNewWindowAdmissionNeverRefunds(remaining: String?) async throws {
        let store = makeStore(), now = Instant(), item = request(.init(), route: "GET /late-old")
        let first = try await admit(store, item, at: now)
        try await store.complete(first, status: 200, headers: headers(limit: 5, remaining: 4, reset: "0.1"), now: now)
        let old = try await admit(store, item, at: now)
        let nextWindow = now.advanced(by: .milliseconds(100))
        let fresh = try await admit(store, item, at: nextWindow)
        try await store.complete(fresh, status: 200, headers: headers(limit: 5, remaining: 4, reset: "0.1"), now: nextWindow)
        let late = nextWindow.advanced(by: .milliseconds(1))
        var metadata = headers(limit: 5, remaining: nil, reset: "0.001")
        if let remaining { metadata.append(.init(name: "X-RateLimit-Remaining", value: remaining)) }
        try await store.complete(old, status: 200, headers: metadata, now: late)
        if remaining != "0" { try await consume(store, item, count: 3, at: late) }
        try await blocked(store, item, at: late, until: nextWindow.advanced(by: .milliseconds(100)))
        #expect(await store.snapshot().activeCount == 0)
    }

    /// Real 429 provenance survives alias discovery even when that response has no remaining header.
    /// Positive sibling metadata may not erase the explicit block or substitute the ten-second startup window.
    /// - Parameter restrictedFirst: Whether the blocked provisional route or the healthy learned route completes first.
    /// - Throws: Unexpected authority errors or a missing required admission.
    @Test(arguments: [true, false])
    func real429SurvivesPositiveAliasMetadata(restrictedFirst: Bool) async throws {
        let store = makeStore(), now = Instant(), identity = RateLimitIdentity()
        let a = request(identity, route: "GET /restricted/a"), b = request(identity, route: "GET /restricted/b")
        let healthy = try await admit(store, a, at: now), restricted = try await admit(store, b, at: now)
        if restrictedFirst {
            try await store.complete(restricted, status: 429, headers: headers(limit: nil, remaining: nil, reset: nil),
                                     retryAfter: .seconds(2), now: now)
        }
        try await store.complete(healthy, status: 200, headers: headers(remaining: 9, reset: "1"), now: now)
        if !restrictedFirst {
            try await store.complete(restricted, status: 429, headers: headers(limit: nil, remaining: nil, reset: nil),
                                     retryAfter: .seconds(2), now: now)
        }
        for item in [a, b] { try await blocked(store, item, at: now, until: now.advanced(by: .seconds(2))) }
        let later = now.advanced(by: .seconds(2)), next = try await admit(store, a, at: now.advanced(by: .seconds(2)))
        try await store.release(next, outcome: .notSent, now: later)
        #expect(await store.snapshot().activeCount == 0)
    }

    /// Route, credential-global, major-resource shared and outbound-IP-global restrictions retain separate exact scopes.
    /// - Parameter scope: The existing server restriction family exercised without altering coordinator policy.
    /// - Throws: Unexpected authority errors or a missing required admission.
    @Test(arguments: ["route", "global", "shared", "egress-global", "invalid-egress"])
    func independentRestrictionScopesRemainClosed(scope: String) async throws {
        let store = makeStore(invalidThreshold: scope == "invalid-egress" ? 1 : 9_000)
        let now = Instant(), identity = RateLimitIdentity(), egress = UUID()
        let original = RateLimitRequest(identity: identity, route: "GET /scope/original", majorResource: "channel-1",
            egress: egress, usesGlobalLimit: true, usesEgressGlobalLimit: scope == "egress-global")
        let token = try await admit(store, original, at: now)
        var metadata: [HTTPHeader] = [.init(name: "Retry-After", value: "1.5")]
        if scope == "shared" { metadata.append(.init(name: "X-RateLimit-Scope", value: "shared")) }
        try await store.complete(token, status: scope == "invalid-egress" ? 401 : 429, headers: metadata,
            retryAfter: .seconds(2), global: scope == "global" || scope == "egress-global", now: now)
        let blockedIdentity = scope == "shared" || scope == "egress-global" || scope == "invalid-egress" ? RateLimitIdentity() : identity
        let denied = RateLimitRequest(identity: blockedIdentity,
            route: scope == "route" ? original.route : "GET /scope/other", majorResource: "channel-1", egress: egress,
            usesGlobalLimit: true, usesEgressGlobalLimit: scope == "egress-global")
        try await blocked(store, denied, at: now, until: now.advanced(by: .seconds(2)))
        if scope == "route" {
            let unrelated = RateLimitRequest(identity: identity, route: "GET /scope/unrelated", egress: egress)
            let unrelatedToken = try await admit(store, unrelated, at: now)
            try await store.release(unrelatedToken, outcome: .notSent, now: now)
        }
        if scope == "global" || scope == "egress-global" {
            let exempt = RateLimitRequest(identity: identity, route: "POST /interactions/{id}/callback", egress: egress,
                usesGlobalLimit: false, usesEgressGlobalLimit: scope == "egress-global")
            let exemptToken = try await admit(store, exempt, at: now)
            try await store.release(exemptToken, outcome: .notSent, now: now)
        }
        let independent = RateLimitRequest(identity: .init(), route: "GET /scope/independent", majorResource: "channel-2",
            egress: UUID(), usesGlobalLimit: true, usesEgressGlobalLimit: scope == "egress-global")
        let independentToken = try await admit(store, independent, at: now)
        try await store.release(independentToken, outcome: .uncertain, now: now)
        #expect(await store.snapshot().activeCount == 0)
    }

    /// Malformed response fields cannot supply headroom or shorten startup/429 restrictions during bucket discovery.
    /// - Parameter invalid: Nonfinite, negative, oversized or malformed wire metadata.
    /// - Throws: Unexpected authority errors or a missing required admission.
    @Test(arguments: ["NaN", "inf", "-1", "9999999999999999999999", "invalid"])
    func malformedMetadataDoesNotManufactureAllowance(invalid: String) async throws {
        for status in [200, 429] {
            let store = makeStore(), now = Instant(), item = request(.init(), route: "GET /malformed")
            let token = try await admit(store, item, at: now)
            try await store.complete(token, status: status, headers: [
                .init(name: "X-RateLimit-Bucket", value: "common"),
                .init(name: "X-RateLimit-Limit", value: invalid), .init(name: "X-RateLimit-Remaining", value: invalid),
                .init(name: "X-RateLimit-Reset-After", value: invalid), .init(name: "Retry-After", value: invalid)
            ], now: now)
            try await blocked(store, item, at: now, until: now.advanced(by: .seconds(10)))
            #expect(await store.snapshot().activeCount == 0)
        }
    }

    /// A response with no remaining count retains the exact possible-send debit rather than acknowledging another owner.
    /// - Throws: Unexpected authority errors or a missing required admission.
    @Test func missingMetadataRetainsStartupDebit() async throws {
        for metadata in [[HTTPHeader](), [.init(name: "X-RateLimit-Bucket", value: "common")]] {
            let store = makeStore(), now = Instant(), item = request(.init(), route: "GET /missing")
            let token = try await admit(store, item, at: now)
            try await store.complete(token, status: 200, headers: metadata, now: now)
            try await blocked(store, item, at: now, until: now.advanced(by: .seconds(10)))
        }
    }

    /// Neither release outcome refunds allowance or lets a higher overlapping response erase an uncertain send.
    /// - Parameter notSent: Chooses explicit not-sent or uncertain cleanup under the same no-refund contract.
    /// - Throws: Unexpected authority errors or a missing required admission.
    @Test(arguments: [true, false])
    func releaseAndOverlappingResponseNeverRefund(notSent: Bool) async throws {
        let store = makeStore(), now = Instant(), item = request(.init(), route: "GET /release")
        let first = try await admit(store, item, at: now)
        try await store.complete(first, status: 200, headers: headers(limit: 3, remaining: 2), now: now)
        let completing = try await admit(store, item, at: now), released = try await admit(store, item, at: now)
        try await store.release(released, outcome: notSent ? .notSent : .uncertain, now: now)
        try await store.complete(completing, status: 200, headers: headers(limit: 3, remaining: 2), now: now)
        try await blocked(store, item, at: now, until: now.advanced(by: .seconds(10)))
        #expect(await store.snapshot().activeCount == 0)
    }

    /// Inclusive lease expiry rejects stale learning, clears concurrency and preserves its consumed live-window debit.
    /// - Throws: Unexpected authority errors or a missing required admission.
    @Test func expiredCompletionCannotLearnOrRefund() async throws {
        let store = makeStore(lifetime: .milliseconds(100)), now = Instant()
        let item = request(.init(), route: "GET /expired")
        let first = try await admit(store, item, at: now)
        try await store.complete(first, status: 200, headers: headers(remaining: 9), now: now)
        let expired = try await admit(store, item, at: now), later = now.advanced(by: .milliseconds(100))
        await #expect(throws: RateLimitFailure.reservationExpired) {
            try await store.complete(expired, status: 200, headers: headers(remaining: 999, reset: "0"), now: later)
        }
        try await consume(store, item, count: 8, at: later)
        try await blocked(store, item, at: later, until: now.advanced(by: .seconds(10)))
        #expect(await store.snapshot().activeCount == 0)
    }

    /// Alias learning fits its exact budget/alias ceiling and cannot evict learned state to admit new identities.
    /// - Throws: Unexpected authority errors or a missing required admission.
    @Test func aliasMetadataRemainsBounded() async throws {
        let store = makeStore(metadata: 2), now = Instant(), identity = RateLimitIdentity()
        let item = request(identity, route: "GET /bounded")
        let token = try await admit(store, item, at: now)
        try await store.complete(token, status: 200, headers: headers(remaining: 9), now: now)
        await #expect(throws: RateLimitFailure.metadataFull) {
            _ = try await store.reserve(request(identity, route: "GET /bounded/new"), now: now)
        }
        let snapshot = await store.snapshot()
        #expect(snapshot.activeCount == 0 && snapshot.metadataCount == 2)
    }

    /// Creates finite scenario policy with a ten-second provisional window to expose accidental startup inheritance.
    /// - Parameters:
    ///   - metadata: Aggregate key/alias ceiling; two forces one partition for exact capacity checks.
    ///   - lifetime: Inclusive reservation expiry in the same virtual time domain.
    ///   - invalidThreshold: Outbound-IP invalid-response threshold; one isolates the protection-scope case.
    /// - Returns: Empty production authority with no tasks or external dependencies.
    private func makeStore(metadata: Int = 4_096, lifetime: Duration = .seconds(60), invalidThreshold: Int = 9_000) -> Store {
        Store(policy: .init(maximumConcurrentRequestsPerIdentity: 32, maximumMetadata: metadata,
            reservationLifetime: lifetime, provisionalWindow: .seconds(10),
            invalidRequestThreshold: invalidThreshold, invalidRequestWindow: .seconds(2)))
    }

    /// Creates a route-only request so direct bucket arithmetic is independent of startup credential-global budgets.
    /// - Parameters:
    ///   - identity: Shared opaque credential identity for the scenario.
    ///   - route: Fixed synthetic canonical route, never a real URL or credential.
    /// - Returns: An interaction-exempt direct rate-store input.
    private func request(_ identity: RateLimitIdentity, route: String) -> RateLimitRequest {
        .init(identity: identity, route: route, usesGlobalLimit: false)
    }

    /// Builds explicit valid server metadata; omitted fields are genuinely absent rather than malformed placeholders.
    /// - Parameters:
    ///   - bucket: Opaque shared hash or nil to retain only route-local state.
    ///   - limit: Positive server limit or nil to retain the existing bounded limit.
    ///   - remaining: Nonnegative observed allowance or nil for an unacknowledged possible-send debit.
    ///   - reset: Relative server window spelling or nil for missing reset evidence.
    /// - Returns: Ordered wire headers consumed by the real parser.
    private func headers(bucket: String? = "common", limit: Int? = 10, remaining: Int?, reset: String? = "10") -> [HTTPHeader] {
        var result: [HTTPHeader] = []
        if let bucket { result.append(.init(name: "X-RateLimit-Bucket", value: bucket)) }
        if let limit { result.append(.init(name: "X-RateLimit-Limit", value: String(limit))) }
        if let remaining { result.append(.init(name: "X-RateLimit-Remaining", value: String(remaining))) }
        if let reset { result.append(.init(name: "X-RateLimit-Reset-After", value: reset)) }
        return result
    }

    /// Requires immediate permission and returns its exact cleanup obligation without advancing time.
    /// - Parameters:
    ///   - store: Scenario-local production rate authority.
    ///   - item: Exact original admission scope.
    ///   - now: Explicit ManualClock instant.
    /// - Returns: Owned single-use reservation.
    /// - Throws: Authority failures or a recorded missing-admission requirement.
    private func admit(_ store: Store, _ item: RateLimitRequest, at now: Instant) async throws -> Reservation {
        let result = try await store.reserve(item, now: now)
        guard case .admitted(let token) = result else {
            Issue.record("Expected immediate allowance under explicit virtual-time evidence")
            throw RateLimitFailure.coordinatorUnavailable
        }
        return token
    }

    /// Consumes exactly the expected headroom, releasing every owner uncertain without refunding a debit.
    /// - Parameters:
    ///   - store: Scenario-local production authority.
    ///   - item: Learned route whose shared headroom is being inspected.
    ///   - count: Exact expected finite immediate admission count.
    ///   - now: Unchanged virtual instant, so no replenishment can hide over-admission.
    /// - Throws: Authority failures or any unexpectedly missing permission.
    private func consume(_ store: Store, _ item: RateLimitRequest, count: Int, at now: Instant) async throws {
        for _ in 0..<count {
            let token = try await admit(store, item, at: now)
            try await store.release(token, outcome: .uncertain, now: now)
        }
    }

    /// Requires refusal until at least a known restriction deadline; unexpected permission is always released.
    /// - Parameters:
    ///   - store: Scenario-local production authority.
    ///   - item: Scope expected to remain unavailable.
    ///   - now: Explicit attempted admission instant.
    ///   - minimum: Earliest safe retry established by policy or server evidence.
    /// - Throws: Unexpected authority/cleanup failures.
    private func blocked(_ store: Store, _ item: RateLimitRequest, at now: Instant, until minimum: Instant) async throws {
        switch try await store.reserve(item, now: now) {
        case .retry(let retry): #expect(retry >= minimum && retry > now)
        case .admitted(let token):
            try await store.release(token, outcome: .uncertain, now: now)
            Issue.record("Unexpected allowance before the retained restriction expired")
        }
    }
}
