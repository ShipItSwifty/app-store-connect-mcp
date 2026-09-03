import Foundation

/// How ``AppStoreConnectClient`` retries requests that failed for a reason that is
/// likely to go away on its own.
///
/// App Store Connect answers a burst with `429 TOO_MANY_REQUESTS`, and its edge
/// occasionally returns a bare `500`/`502`/`503` for a request that succeeds a second
/// later. Without a retry, a single blip fails a whole investigation — an agent walking
/// products → workflows → runs → issues issues dozens of requests, so the chance of
/// hitting one is not small.
///
/// Only idempotent-by-nature failures are retried: `GET` at any status below, and
/// non-`GET` only for `429`, which Apple returns *before* applying the request.
public struct TransientRetryPolicy: Sendable {
    /// Total attempts, including the first. `1` disables retrying.
    public let maxAttempts: Int

    /// Delay before the second attempt; doubled for each further attempt.
    public let baseDelay: Duration

    /// Ceiling for any single wait, including one asked for by `Retry-After`.
    public let maxDelay: Duration

    /// HTTP status codes worth retrying.
    public static let retryableStatusCodes: Set<Int> = [429, 500, 502, 503, 504]

    /// Creates a `TransientRetryPolicy`.
    public init(
        maxAttempts: Int = 3,
        baseDelay: Duration = .seconds(1),
        maxDelay: Duration = .seconds(30)
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    /// Retry twice after the first attempt, backing off 1s then 2s.
    public static let `default` = TransientRetryPolicy()

    /// Never retry — the request is performed exactly once.
    public static let disabled = TransientRetryPolicy(maxAttempts: 1)

    /// Whether a response with this status on this method should be retried.
    public func shouldRetry(statusCode: Int, method: String) -> Bool {
        guard Self.retryableStatusCodes.contains(statusCode) else { return false }
        // A 5xx on a POST/PATCH may have applied server-side; replaying it could
        // duplicate a resource. 429 is refused before any work happens, so it is safe.
        return method.uppercased() == "GET" || statusCode == 429
    }

    /// The wait before `attempt` (1-based: the wait *after* attempt 1 failed),
    /// honouring a server-supplied `Retry-After` when it asks for a longer pause.
    func delay(forAttempt attempt: Int, retryAfter: Duration?) -> Duration {
        let backoff = baseDelay * pow(2.0, Double(max(0, attempt - 1)))
        let chosen = max(backoff, retryAfter ?? .zero)
        return min(chosen, maxDelay)
    }

    /// Parses a `Retry-After` header, which Apple sends as a whole number of seconds.
    /// HTTP-date form is ignored rather than mis-parsed — the exponential backoff
    /// still applies.
    static func retryAfter(from headers: [String: String]) -> Duration? {
        guard let raw = headers["Retry-After"] ?? headers["retry-after"],
            let seconds = Double(raw.trimmingCharacters(in: .whitespaces)),
            seconds > 0
        else { return nil }
        return .seconds(seconds)
    }
}
