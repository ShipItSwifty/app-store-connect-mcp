import AppStoreConnectKit
import Foundation
import MCP

/// Tools for the questions that surround a submission rather than the submission
/// itself: how far a staged rollout has got, what App Review was told, what the
/// app-level metadata record says, and whether the signing assets are still valid.
///
/// Part of the single catalog; see ``CITools/specs``.
enum ReviewTools {
    static let specs: [ToolSpec] = [
        ToolSpec(
            name: "asc_phased_release_status",
            description: """
                Report the staged rollout of an App Store version: state (INACTIVE / ACTIVE / \
                PAUSED / COMPLETE), which day of Apple's fixed 7-day schedule it is on, the \
                share of users that reaches, the start date, and how long it has been paused. \
                Pass a version_id, or an app_id/bundle_id to use the newest version. Returns \
                {"configured": false} when the version releases without a phased rollout.
                """,
            arguments: [
                .string("version_id", "App Store version id. Omit to use the app's newest version."),
                .string("app_id", "App Store Connect app id — resolves to its newest version."),
                .string("bundle_id", "Bundle identifier — resolves to its newest version."),
            ]
        ) { args, makeClient in
            let client = try makeClient()
            let versionID = try await resolveVersionID(args, client: client)
            guard let release = try await client.phasedRelease(versionID: versionID) else {
                return try json(PhasedReleaseReport(configured: false, versionID: versionID, release: nil, percentageOfUsers: nil))
            }
            return try json(
                PhasedReleaseReport(
                    configured: true,
                    versionID: versionID,
                    release: release,
                    percentageOfUsers: release.percentageOfUsers
                ))
        },

        ToolSpec(
            name: "asc_review_details",
            description: """
                Read what App Review was told about an app: the reviewer contact, whether a \
                demo account is required and its username, and the free-text notes — for both \
                App Store review (per version) and Beta App Review (per app, for TestFlight \
                external testing). A required-but-missing demo account is a routine rejection \
                cause and is visible here. Demo account passwords are never returned. \
                Pass either app_id or bundle_id.
                """,
            arguments: [
                .string("app_id", "App Store Connect app id (or pass bundle_id)."),
                .string("bundle_id", "Bundle identifier, resolved to an app id."),
                .string("version_id", "App Store version id. Omit to use the app's newest version."),
            ]
        ) { args, makeClient in
            let client = try makeClient()
            let appID = try await AppStoreTools.resolveAppID(args, client: client)
            let versionID = try await resolveVersionID(args, client: client, appID: appID)
            async let appStore = client.appStoreReviewDetail(versionID: versionID)
            async let beta = client.betaAppReviewDetail(appID: appID)
            return try json(
                ReviewDetailsReport(
                    versionID: versionID,
                    appStoreReview: try await appStore,
                    betaAppReview: try await beta
                ))
        },

        ToolSpec(
            name: "asc_list_app_infos",
            description: """
                Read an app's app-level listing records: the state of each (which is reviewed \
                separately from any one version, so an app can be METADATA_REJECTED while the \
                version itself looks fine) and the computed age ratings, including the \
                per-territory ones. Pass either app_id or bundle_id.
                """,
            arguments: [
                .string("app_id", "App Store Connect app id (or pass bundle_id)."),
                .string("bundle_id", "Bundle identifier, resolved to an app id."),
                .integer("limit", "Max app infos to return (default 10)."),
            ]
        ) { args, makeClient in
            let client = try makeClient()
            return try json(
                await client.appInfos(
                    appID: try await AppStoreTools.resolveAppID(args, client: client),
                    limit: args.int("limit", default: 10)
                ))
        },

        ToolSpec(
            name: "asc_signing_assets",
            description: """
                List the team's signing certificates and provisioning profiles with their \
                expiry dates, and call out the ones that will break a build: already expired, \
                expiring within 'within_days' (default 30), or profiles Apple marked INVALID \
                because a certificate or device they reference was revoked. Use this when a \
                build that worked last week now fails to sign — it is usually one of these \
                three, and the CI log only says the signing failed.
                """,
            arguments: [
                .integer("within_days", "Warn about assets expiring within this many days (default 30)."),
                .integer("limit", "Max assets of each kind to fetch (default 200)."),
            ]
        ) { args, makeClient in
            try json(
                await makeClient().signingAssets(
                    withinDays: args.int("within_days", default: 30, max: 365),
                    limit: args.int("limit", default: 200)
                ))
        },
    ]

    // MARK: - Payloads

    /// `asc_phased_release_status` payload.
    private struct PhasedReleaseReport: Encodable {
        let configured: Bool
        let versionID: String
        let release: ASCPhasedRelease?
        /// The share of users day `currentDayNumber` reaches, which the API does not return.
        let percentageOfUsers: Int?
    }

    /// `asc_review_details` payload.
    private struct ReviewDetailsReport: Encodable {
        let versionID: String
        let appStoreReview: ASCReviewDetail?
        let betaAppReview: ASCReviewDetail?
    }

    // MARK: - Helpers

    /// Resolves `version_id`, or the newest App Store version of the resolved app.
    private static func resolveVersionID(
        _ args: ToolArguments,
        client: AppStoreConnectClient,
        appID: String? = nil
    ) async throws -> String {
        if let versionID = args.string("version_id") { return versionID }
        let resolvedAppID: String
        if let appID {
            resolvedAppID = appID
        } else {
            resolvedAppID = try await AppStoreTools.resolveAppID(args, client: client)
        }
        let versions = try await client.appStoreVersions(appID: resolvedAppID, limit: 1)
        guard let version = versions.data.first else {
            throw ASCError.apiError(statusCode: 404, body: "App '\(resolvedAppID)' has no App Store versions.")
        }
        return version.id
    }

    private static func json<T: Encodable>(_ value: T) throws -> CallTool.Result {
        try CITools.json(value)
    }
}
