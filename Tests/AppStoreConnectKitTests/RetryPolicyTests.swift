import Foundation
import Testing

@testable import AppStoreConnectKit

@Suite("RetryPolicy")
struct RetryPolicyTests {
    private struct Boom: Error {}

    @Test("Sub-second delays still grow between attempts")
    func subSecondBackoffGrows() async throws {
        // The backoff used to be recomputed from `Duration.components.seconds`, which
        // truncated any sub-second delay to zero and flattened every later attempt.
        let policy = RetryPolicy(maxAttempts: 3, initialDelay: .milliseconds(20), multiplier: 2.0)
        let calls = Counter()

        let start = ContinuousClock.now
        await #expect(throws: Boom.self) {
            try await policy.execute {
                await calls.increment()
                throw Boom()
            }
        }
        let elapsed = ContinuousClock.now - start

        #expect(await calls.value == 3)
        // 20ms before attempt 2 plus 40ms before attempt 3; a collapsed backoff
        // would finish in well under that.
        #expect(elapsed >= .milliseconds(55))
    }

    @Test("Returns immediately on first success without retrying")
    func firstTrySucceeds() async throws {
        let policy = RetryPolicy(maxAttempts: 3, initialDelay: .zero)
        let calls = Counter()
        let result = try await policy.execute {
            await calls.increment()
            return 42
        }
        #expect(result == 42)
        #expect(await calls.value == 1)
    }

    @Test("Retries until an attempt succeeds")
    func succeedsAfterRetries() async throws {
        let policy = RetryPolicy(maxAttempts: 5, initialDelay: .zero)
        let calls = Counter()
        let result = try await policy.execute { () async throws -> String in
            let n = await calls.increment()
            if n < 3 { throw Boom() }
            return "ok"
        }
        #expect(result == "ok")
        #expect(await calls.value == 3)
    }

    @Test("Throws the last error after exhausting maxAttempts")
    func exhaustsAttempts() async {
        let policy = RetryPolicy(maxAttempts: 3, initialDelay: .zero)
        let calls = Counter()
        await #expect(throws: Boom.self) {
            try await policy.execute { () async throws -> Int in
                _ = await calls.increment()
                throw Boom()
            }
        }
        #expect(await calls.value == 3)
    }

    @Test("maxAttempts of 1 means no retries")
    func singleAttempt() async {
        let policy = RetryPolicy(maxAttempts: 1, initialDelay: .zero)
        let calls = Counter()
        await #expect(throws: Boom.self) {
            try await policy.execute { () async throws -> Int in
                _ = await calls.increment()
                throw Boom()
            }
        }
        #expect(await calls.value == 1)
    }
}

/// Minimal async-safe call counter.
private actor Counter {
    private(set) var value = 0

    @discardableResult
    func increment() -> Int {
        value += 1
        return value
    }
}
