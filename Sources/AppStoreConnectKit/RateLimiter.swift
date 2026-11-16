import Foundation
import Logging

/// A point-in-time view of the App Store Connect hourly rate limit.
public struct RateLimitStatus: Codable, Sendable {
    /// Requests permitted per rolling hour.
    public let limit: Int
    /// Requests still available this hour.
    public let remaining: Int
    /// Fraction of the hourly limit consumed (`0...1`).
    public let usedFraction: Double
    /// The fraction at which ``RateLimiter`` starts pausing requests.
    public let throttleThreshold: Double

    /// Consumed percentage, rounded to a whole number (for display).
    public var usedPercent: Int { Int((usedFraction * 100).rounded()) }

    /// `true` once usage is within 10 points of the throttle threshold — the point
    /// at which a long investigation risks stalling on backoff.
    public var isNearLimit: Bool { usedFraction >= max(0, throttleThreshold - 0.1) }

    /// Creates a `RateLimitStatus`.
    public init(limit: Int, remaining: Int, usedFraction: Double, throttleThreshold: Double) {
        self.limit = limit
        self.remaining = remaining
        self.usedFraction = usedFraction
        self.throttleThreshold = throttleThreshold
    }
}

/// Tracks App Store Connect API rate limits and enforces backoff.
///
/// Reads `X-Rate-Limit` headers from responses and delays requests
/// when approaching the hourly threshold (default: pause at 90% usage).
///
/// Apple's rate limit header format:
/// ```
/// X-Rate-Limit: user-hour-lim:3500;user-hour-rem:2998
/// ```
///
/// ## Usage
/// ```swift
/// let limiter = RateLimiter()
/// // Before each API request:
/// await limiter.throttleIfNeeded()
/// // After each response:
/// await limiter.update(from: responseHeaders)
/// ```
public actor RateLimiter {
    /// The fraction of the limit at which throttling begins (0.9 = 90% used).
    public let throttleThreshold: Double

    /// The longest pause between two throttled requests, reached as the hourly budget
    /// runs out. The pause starts at a tenth of this when usage first crosses
    /// ``throttleThreshold``.
    public let maxBackoff: Duration

    private var hourlyLimit: Int?
    private var hourlyRemaining: Int?
    /// When a complete `X-Rate-Limit` header was last parsed. Package-internal so
    /// tests can age it without sleeping.
    private(set) var lastUpdated: ContinuousClock.Instant?
    /// The earliest moment the next throttled request may go out. Shared by every
    /// caller, so concurrent requests queue behind one another instead of all
    /// sleeping the same backoff and then firing together.
    private var nextThrottledSlot: ContinuousClock.Instant?
    private let logger = Logger.forType(subsystem: "AppStoreConnectKit", RateLimiter.self)

    /// Creates a `RateLimiter`.
    ///
    /// - Parameters:
    ///   - throttleThreshold: Fraction (0–1) of hourly limit at which to pause.
    ///     Defaults to `0.9` (pause when 90% of the limit is consumed).
    ///   - maxBackoff: The pause between throttled requests once the budget is
    ///     exhausted. Defaults to 5 seconds.
    public init(throttleThreshold: Double = 0.9, maxBackoff: Duration = .seconds(5)) {
        self.throttleThreshold = throttleThreshold
        self.maxBackoff = maxBackoff
    }

    /// Delay execution if the rate limit is approaching the throttle threshold.
    ///
    /// Below the threshold this returns at once. Past it, requests are spaced out by a
    /// pause that grows from a tenth of ``maxBackoff`` at the threshold to the whole of
    /// it when nothing remains, so a long investigation slows gradually rather than
    /// hitting a flat wall. The spacing is global: concurrent callers wait their turn.
    public func throttleIfNeeded() async {
        guard let limit = hourlyLimit, let remaining = hourlyRemaining,
            let delay = Self.backoff(
                limit: limit, remaining: remaining, threshold: throttleThreshold, maxBackoff: maxBackoff)
        else {
            if let fraction = usageFraction {
                logger.debug("Rate limit OK: \(Int(fraction * 100))% of the hourly budget used")
            }
            return
        }

        let now = ContinuousClock.now
        let start = max(now, nextThrottledSlot ?? now)
        let fireAt = start + delay
        nextThrottledSlot = fireAt
        logger.warning(
            "Rate limit nearly spent (\(remaining)/\(limit) remaining). Pausing \(now.duration(to: fireAt)) before the next request."
        )
        try? await Task.sleep(until: fireAt, clock: .continuous)
    }

    /// The pause before a request at this position, or `nil` when usage is below the
    /// threshold. Grows linearly from `maxBackoff / 10` at the threshold to `maxBackoff`
    /// with nothing remaining.
    static func backoff(limit: Int, remaining: Int, threshold: Double, maxBackoff: Duration) -> Duration? {
        guard limit > 0 else { return nil }
        let used = Double(limit - remaining) / Double(limit)
        guard used >= threshold else { return nil }
        let band = Swift.max(1 - threshold, .ulpOfOne)
        let depth = Swift.min(Swift.max((used - threshold) / band, 0), 1)
        return maxBackoff * (0.1 + 0.9 * depth)
    }

    /// Update rate limit state from an HTTP response's headers.
    ///
    /// Parses `X-Rate-Limit: user-hour-lim:3500;user-hour-rem:2998`.
    ///
    /// - Parameter headers: Dictionary of HTTP response header fields.
    public func update(from headers: [String: String]) {
        guard let header = headers["X-Rate-Limit"] ?? headers["x-rate-limit"] else {
            return
        }
        guard let parsed = parse(header: header) else { return }
        hourlyLimit = parsed.limit
        hourlyRemaining = parsed.remaining
        lastUpdated = .now
        logger.debug("Rate limit updated: \(parsed.remaining)/\(parsed.limit) remaining this hour")
    }

    /// The most recently parsed `(limit, remaining)` pair, or `nil` before any
    /// response headers have been seen. Package-internal — used by tests to assert
    /// header parsing without waiting on a real backoff sleep.
    var snapshot: (limit: Int, remaining: Int)? {
        guard let hourlyLimit, let hourlyRemaining else { return nil }
        return (hourlyLimit, hourlyRemaining)
    }

    /// Fraction of the hourly limit currently consumed (`0...1`), or `nil` if unknown.
    var usageFraction: Double? {
        guard let hourlyLimit, let hourlyRemaining, hourlyLimit > 0 else { return nil }
        return Double(hourlyLimit - hourlyRemaining) / Double(hourlyLimit)
    }

    /// A serializable snapshot of the current hourly rate-limit position, or `nil`
    /// before any response headers have been seen. Consumers (e.g. the MCP server)
    /// use this to warn an agent that it is approaching the throttle threshold.
    public func status() -> RateLimitStatus? {
        guard let hourlyLimit, let hourlyRemaining, hourlyLimit > 0 else { return nil }
        let used = Double(hourlyLimit - hourlyRemaining) / Double(hourlyLimit)
        return RateLimitStatus(
            limit: hourlyLimit,
            remaining: hourlyRemaining,
            usedFraction: used,
            throttleThreshold: throttleThreshold
        )
    }

    /// The current position, but only if a response reported it within `maxAge`.
    ///
    /// Lets a caller that wants the position skip a request made purely to learn it
    /// when another call has just seen the header. Returns `nil` when nothing recent
    /// is known.
    public func status(maxAge: Duration) -> RateLimitStatus? {
        status(maxAge: maxAge, now: .now)
    }

    /// ``status(maxAge:)`` against an explicit clock reading, for tests.
    func status(maxAge: Duration, now: ContinuousClock.Instant) -> RateLimitStatus? {
        guard let lastUpdated, lastUpdated.duration(to: now) <= maxAge else { return nil }
        return status()
    }

    // MARK: - Private

    private func parse(header: String) -> (limit: Int, remaining: Int)? {
        // Format: "user-hour-lim:3500;user-hour-rem:2998"
        var limit: Int?
        var remaining: Int?
        let parts = header.components(separatedBy: ";")
        for part in parts {
            let kv = part.components(separatedBy: ":")
            guard kv.count == 2 else { continue }
            let key = kv[0].trimmingCharacters(in: .whitespaces)
            let value = kv[1].trimmingCharacters(in: .whitespaces)
            if key == "user-hour-lim", let intValue = Int(value) {
                limit = intValue
            } else if key == "user-hour-rem", let intValue = Int(value) {
                remaining = intValue
            }
        }
        guard let limit, let remaining else { return nil }
        return (limit, remaining)
    }
}
