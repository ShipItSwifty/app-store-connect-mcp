import Foundation

/// Errors thrown by ``AppStoreConnectClient`` and the services built on top of it.
///
/// Consumers that need their own error taxonomy (for example a CLI mapping cases to
/// exit codes) should catch `ASCError` at their boundary and translate it.
public enum ASCError: Error, Sendable {
    /// The App Store Connect API returned a non-2xx HTTP status.
    case apiError(statusCode: Int, body: String)

    /// JWT generation failed (bad key, missing fields, unsupported encoding).
    case jwtGenerationFailed(underlying: any Error)

    /// An asset upload to App Store Connect failed after any retries.
    case uploadFailed(asset: String, reason: String)

    /// A request could not be built or credentials were missing/invalid.
    case invalidConfiguration(reason: String)

    /// A 2xx response body did not match the model this package expects. Carries the
    /// request path and the target type so the mismatch is attributable — App Store
    /// Connect adds and removes attributes without notice.
    case decodingFailed(path: String, type: String, underlying: any Error)
}

extension ASCError: LocalizedError {
    /// A human-readable description of the error.
    public var errorDescription: String? {
        switch self {
        case .apiError(let statusCode, let body):
            let detail = Self.ascErrorDetail(from: body) ?? body
            return "App Store Connect API error (\(statusCode)): \(detail)"
        case .jwtGenerationFailed(let underlying):
            return "JWT generation failed: \(underlying.localizedDescription)"
        case .uploadFailed(let asset, let reason):
            return "Upload failed for \(asset): \(reason)"
        case .invalidConfiguration(let reason):
            return "Invalid configuration: \(reason)"
        case .decodingFailed(let path, let type, let underlying):
            return "Could not decode \(type) from \(path): \(underlying)"
        }
    }
}

extension ASCError {
    /// Pulls the first entry's `detail` (and `title`, when it adds information) out of a
    /// JSON:API error body, so a thrown `apiError` names the actual failure — e.g.
    /// "The specified pre-release build could not be added." — instead of only a status
    /// code plus an opaque blob. Returns `nil` when the body is not a JSON:API error
    /// document, leaving callers to fall back to the raw body.
    static func ascErrorDetail(from body: String) -> String? {
        guard let data = body.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let errors = root["errors"] as? [[String: Any]],
            let first = errors.first
        else { return nil }

        let detail = (first["detail"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (first["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let extra = errors.count > 1 ? " (+\(errors.count - 1) more)" : ""

        switch (title, detail) {
        case (let title?, let detail?) where !title.isEmpty && !detail.isEmpty && title != detail:
            return "\(title): \(detail)\(extra)"
        case (_, let detail?) where !detail.isEmpty:
            return detail + extra
        case (let title?, _) where !title.isEmpty:
            return title + extra
        default:
            return nil
        }
    }
}
