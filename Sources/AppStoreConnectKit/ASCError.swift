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
}

extension ASCError: LocalizedError {
    /// A human-readable description of the error.
    public var errorDescription: String? {
        switch self {
        case .apiError(let statusCode, let body):
            return "App Store Connect API error (\(statusCode)): \(body)"
        case .jwtGenerationFailed(let underlying):
            return "JWT generation failed: \(underlying.localizedDescription)"
        case .uploadFailed(let asset, let reason):
            return "Upload failed for \(asset): \(reason)"
        case .invalidConfiguration(let reason):
            return "Invalid configuration: \(reason)"
        }
    }
}
