import Foundation
import Logging

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

public actor RateLimiter {
    /// The fraction of the limit at which throttling begins (0.9 = 90% used).
    public let throttleThreshold: Double

    private var hourlyLimit: Int?
    private var hourlyRemaining: Int?
    private let logger = Logger.forType(subsystem: "AppStoreConnectKit", RateLimiter.self)

    /// Creates a `RateLimiter`.
    ///
    /// - Parameter throttleThreshold: Fraction (0–1) of hourly limit at which to pause.
    ///   Defaults to `0.9` (pause when 90% of the limit is consumed).
    public init(throttleThreshold: Double = 0.9) {
        self.throttleThreshold = throttleThreshold
    }

    /// Delay execution if the rate limit is approaching the throttle threshold.
    ///
    /// Sleeps for a backoff period if fewer than `(1 - throttleThreshold) * limit` requests remain.
    public func throttleIfNeeded() async {
        guard let limit = hourlyLimit, let remaining = hourlyRemaining else {
            // No rate limit data yet; proceed
            return
        }

        let usageFraction = Double(limit - remaining) / Double(limit)
        if usageFraction >= throttleThreshold {
            let backoffSeconds: Double = 5.0
            logger.warning(
                "Rate limit at \(Int(usageFraction * 100))% (\(remaining)/\(limit) remaining). Throttling for \(backoffSeconds)s.")
            try? await Task.sleep(for: .seconds(backoffSeconds))
        } else {
            logger.debug("Rate limit OK: \(remaining)/\(limit) remaining (\(Int(usageFraction * 100))% used)")
        }
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
        parse(header: header)
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

    // MARK: - Private

    private func parse(header: String) {
        // Format: "user-hour-lim:3500;user-hour-rem:2998"
        let parts = header.components(separatedBy: ";")
        for part in parts {
            let kv = part.components(separatedBy: ":")
            guard kv.count == 2 else { continue }
            let key = kv[0].trimmingCharacters(in: .whitespaces)
            let value = kv[1].trimmingCharacters(in: .whitespaces)
            if key == "user-hour-lim", let intValue = Int(value) {
                hourlyLimit = intValue
            } else if key == "user-hour-rem", let intValue = Int(value) {
                hourlyRemaining = intValue
            }
        }
        if let limit = hourlyLimit, let remaining = hourlyRemaining {
            logger.debug("Rate limit updated: \(remaining)/\(limit) remaining this hour")
        }
    }
}
