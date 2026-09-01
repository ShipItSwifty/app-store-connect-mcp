import Foundation
import Testing

@testable import AppStoreConnectKit

@Suite("RateLimiter")
struct RateLimiterTests {
    @Test("Parses Apple's X-Rate-Limit header")
    func parsesHeader() async {
        let limiter = RateLimiter()
        await limiter.update(from: ["X-Rate-Limit": "user-hour-lim:3500;user-hour-rem:2998"])
        let snapshot = await limiter.snapshot
        #expect(snapshot?.limit == 3500)
        #expect(snapshot?.remaining == 2998)
    }

    @Test("Parses the lower-cased header variant")
    func parsesLowercasedHeader() async {
        let limiter = RateLimiter()
        await limiter.update(from: ["x-rate-limit": "user-hour-lim:100;user-hour-rem:10"])
        let fraction = await limiter.usageFraction
        #expect(fraction == 0.9)
    }

    @Test("Ignores malformed or missing headers")
    func ignoresMalformed() async {
        let limiter = RateLimiter()
        await limiter.update(from: ["X-Rate-Limit": "garbage-without-colons"])
        await limiter.update(from: ["Unrelated": "value"])
        let snapshot = await limiter.snapshot
        #expect(snapshot == nil)
    }

    @Test("throttleIfNeeded returns immediately when usage is below threshold")
    func throttleBelowThresholdIsFast() async {
        let limiter = RateLimiter(throttleThreshold: 0.9)
        await limiter.update(from: ["X-Rate-Limit": "user-hour-lim:1000;user-hour-rem:900"])
        let start = ContinuousClock.now
        await limiter.throttleIfNeeded()
        #expect(start.duration(to: .now) < .seconds(1))
    }

    @Test("throttleIfNeeded is a no-op before any headers are seen")
    func throttleWithoutDataIsNoOp() async {
        let limiter = RateLimiter()
        let start = ContinuousClock.now
        await limiter.throttleIfNeeded()
        #expect(start.duration(to: .now) < .seconds(1))
    }

    @Test("Later updates overwrite earlier state")
    func laterUpdatesWin() async {
        let limiter = RateLimiter()
        await limiter.update(from: ["X-Rate-Limit": "user-hour-lim:3500;user-hour-rem:3000"])
        await limiter.update(from: ["X-Rate-Limit": "user-hour-lim:3500;user-hour-rem:1"])
        let snapshot = await limiter.snapshot
        #expect(snapshot?.remaining == 1)
    }
}
