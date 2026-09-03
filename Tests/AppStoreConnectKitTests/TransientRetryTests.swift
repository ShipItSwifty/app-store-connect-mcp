import Foundation
import Testing

@testable import AppStoreConnectKit

/// Covers the retry of transient App Store Connect failures: which statuses and
/// methods qualify, how long the wait is, and that the client actually replays.
@Suite("Transient retry")
struct TransientRetryTests {
    /// Fast enough that a retrying test doesn't add real seconds to the suite.
    private static let fast = TransientRetryPolicy(
        maxAttempts: 3,
        baseDelay: .milliseconds(1),
        maxDelay: .milliseconds(5)
    )

    @Test("429 and 5xx are retryable on GET; only 429 is retryable on a write")
    func retryableStatuses() {
        let policy = TransientRetryPolicy.default
        for status in [429, 500, 502, 503, 504] {
            #expect(policy.shouldRetry(statusCode: status, method: "GET"))
        }
        for status in [400, 401, 403, 404, 409, 422] {
            #expect(!policy.shouldRetry(statusCode: status, method: "GET"))
        }
        // Replaying a POST that may already have been applied could create a duplicate
        // resource; a 429 was refused before any work happened, so it is safe.
        #expect(policy.shouldRetry(statusCode: 429, method: "POST"))
        #expect(!policy.shouldRetry(statusCode: 500, method: "POST"))
        #expect(!policy.shouldRetry(statusCode: 503, method: "PATCH"))
    }

    @Test("Backoff doubles, honours a longer Retry-After, and never exceeds maxDelay")
    func backoffMath() {
        let policy = TransientRetryPolicy(maxAttempts: 5, baseDelay: .seconds(1), maxDelay: .seconds(10))
        #expect(policy.delay(forAttempt: 1, retryAfter: nil) == .seconds(1))
        #expect(policy.delay(forAttempt: 2, retryAfter: nil) == .seconds(2))
        #expect(policy.delay(forAttempt: 3, retryAfter: nil) == .seconds(4))
        // A server asking for longer wins; asking for less does not shorten the backoff.
        #expect(policy.delay(forAttempt: 1, retryAfter: .seconds(7)) == .seconds(7))
        #expect(policy.delay(forAttempt: 3, retryAfter: .seconds(1)) == .seconds(4))
        // The cap applies to both sources of delay.
        #expect(policy.delay(forAttempt: 9, retryAfter: nil) == .seconds(10))
        #expect(policy.delay(forAttempt: 1, retryAfter: .seconds(600)) == .seconds(10))
    }

    @Test("Retry-After is read as whole seconds; an HTTP-date form is ignored, not mis-parsed")
    func retryAfterParsing() {
        #expect(TransientRetryPolicy.retryAfter(from: ["Retry-After": "3"]) == .seconds(3))
        #expect(TransientRetryPolicy.retryAfter(from: ["retry-after": " 12 "]) == .seconds(12))
        #expect(TransientRetryPolicy.retryAfter(from: ["Retry-After": "0"]) == nil)
        #expect(TransientRetryPolicy.retryAfter(from: ["Retry-After": "Wed, 21 Oct 2026 07:28:00 GMT"]) == nil)
        #expect(TransientRetryPolicy.retryAfter(from: [:]) == nil)
    }

    @Test("A GET that is throttled once succeeds on the retry")
    func clientRetriesThrottledGet() async throws {
        let client = makeClient(
            responses: [
                .response(statusCode: 429, headers: ["Retry-After": "0"], body: Data("{}".utf8)),
                .json(["data": [["id": "app-1", "attributes": ["bundleId": "com.example.app"]]]]),
            ],
            retryPolicy: Self.fast
        )

        let apps = try await client.apps()
        #expect(apps.data.first?.attributes?.bundleId == "com.example.app")
    }

    @Test("Retries stop at maxAttempts and surface the last error")
    func clientGivesUpAfterMaxAttempts() async throws {
        let observed = LockedBox<[String]>([])
        let client = makeClientRecording(
            observedURLs: observed,
            responses: (0..<5).map { _ in .error(statusCode: 503, body: "unavailable") },
            retryPolicy: Self.fast
        )

        await #expect(throws: ASCError.self) { _ = try await client.apps() }
        #expect(observed.value.count == 3, "3 attempts total, not an unbounded loop")
    }

    @Test("A non-retryable status fails on the first attempt")
    func clientDoesNotRetryClientErrors() async throws {
        let observed = LockedBox<[String]>([])
        let client = makeClientRecording(
            observedURLs: observed,
            responses: [.error(statusCode: 403, body: "forbidden"), .json(["data": []])],
            retryPolicy: Self.fast
        )

        await #expect(throws: ASCError.self) { _ = try await client.apps() }
        #expect(observed.value.count == 1)
    }

    @Test("A malformed 2xx body reports the path and the expected type")
    func decodingFailureIsAttributable() async throws {
        let client = makeClient(responses: [.json(["data": "not-a-list"])])

        do {
            _ = try await client.apps()
            Issue.record("expected a decoding failure")
        } catch let error as ASCError {
            guard case .decodingFailed(let path, let type, _) = error else {
                Issue.record("expected decodingFailed, got \(error)")
                return
            }
            #expect(path == "/v1/apps")
            #expect(type.contains("ASCApp"))
            #expect(error.localizedDescription.contains("/v1/apps"))
        }
    }
}
