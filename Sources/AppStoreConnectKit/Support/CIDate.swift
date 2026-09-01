import Foundation

/// Parsing helpers for the ISO-8601 timestamps App Store Connect returns
/// (`createdDate`, `startedDate`, `finishedDate`, …).
///
/// ASC is inconsistent about fractional seconds and the trailing zone (`Z` vs
/// `+00:00`), so we try a couple of `ISO8601DateFormatter` configurations.
enum CIDate {
    // `ISO8601DateFormatter` is documented as thread-safe; parsing here is read-only.
    nonisolated(unsafe) private static let withFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Parses an ASC timestamp string into a `Date`, tolerating optional fractional seconds.
    static func parse(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        return withFractional.date(from: string) ?? plain.date(from: string)
    }

    /// The elapsed wall-clock seconds between two ASC timestamps, or `nil` if either
    /// is missing/unparseable or the interval is negative.
    static func durationSeconds(from start: String?, to end: String?) -> Double? {
        guard let start = parse(start), let end = parse(end) else { return nil }
        let seconds = end.timeIntervalSince(start)
        return seconds >= 0 ? seconds.rounded() : nil
    }
}
