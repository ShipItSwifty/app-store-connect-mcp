import Foundation

// MARK: - Shared wire resources
//
// Minimal decoding shapes for the App Store resources that more than one service
// touches. They stay `internal`: only the normalized reports each service returns
// (`SubmissionStatusReport`, `MetadataSyncResult`, …) are public API, so these can
// grow an attribute without it being a source-breaking change.
//
// Previously each service declared its own private copy, and the two disagreed
// about what an App Store version is — `AppStoreReleaseService` never saw
// `appVersionState`, so it read a stale state on tenants that return the new field.

/// An `appStoreVersions` resource.
struct AppStoreVersionResource: Codable, Sendable {
    let id: String
    let attributes: Attributes?

    struct Attributes: Codable, Sendable {
        let versionString: String?
        let platform: String?
        /// The legacy state field. Newer tenants populate ``appVersionState`` instead,
        /// so read them with ``AppStoreVersionResource/state``.
        let appStoreState: String?
        let appVersionState: String?
        let createdDate: String?
    }

    /// The version's review state, preferring whichever field this tenant populates.
    var state: String? {
        attributes?.appStoreState ?? attributes?.appVersionState
    }
}

/// A `reviewSubmissions` resource.
struct ReviewSubmissionResource: Codable, Sendable {
    let id: String
    let attributes: Attributes?

    struct Attributes: Codable, Sendable {
        /// `READY_FOR_REVIEW`, `WAITING_FOR_REVIEW`, `IN_REVIEW`, `UNRESOLVED_ISSUES`,
        /// `CANCELING`, `COMPLETING`, `COMPLETE`.
        let state: String?
        let platform: String?
        let submittedDate: String?
    }
}

/// A `reviewSubmissionItems` resource.
struct ReviewSubmissionItemResource: Codable, Sendable {
    let id: String
    let attributes: Attributes?

    struct Attributes: Codable, Sendable {
        /// `READY_FOR_REVIEW`, `ACCEPTED`, `APPROVED`, `REJECTED`, `REMOVED`.
        let state: String?
    }
}

/// A `builds` resource.
struct BuildResource: Codable, Sendable {
    let id: String
    let attributes: Attributes?

    struct Attributes: Codable, Sendable {
        let version: String?
        let processingState: String?
        let expired: Bool?
    }
}

// MARK: - Shared lookups

extension AppStoreConnectClient {
    /// Resolves the App Store Connect app for a bundle identifier.
    ///
    /// - Throws: ``ASCError/apiError(statusCode:body:)`` with status 404 when no app
    ///   in the team matches `bundleID`.
    func app(bundleID: String) async throws -> ASCApp {
        let apps: ASCListResponse<ASCApp> = try await get(
            "/v1/apps",
            query: ["filter[bundleId]": bundleID]
        )
        guard let app = apps.data.first else {
            throw ASCError.apiError(
                statusCode: 404,
                body: "App with bundle ID '\(bundleID)' not found in App Store Connect"
            )
        }
        return app
    }
}
