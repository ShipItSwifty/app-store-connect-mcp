import Foundation
import Logging

// MARK: - App Store submission / review diagnostics
//
// When a release stalls, the question is usually "what state is it in, and whose
// turn is it?". The App Store Connect API answers that across three resources:
//
//   * `appStoreVersions`   — the version's own review state (REJECTED, METADATA_REJECTED, …)
//   * `reviewSubmissions`  — the submission envelope state (UNRESOLVED_ISSUES, IN_REVIEW, …)
//   * `reviewSubmissionItems` — per-item outcome (REJECTED / APPROVED / ACCEPTED)
//
// `AppStoreSubmissionService` gathers all three and produces one `SubmissionStatusReport`
// with a plain-language diagnosis, so an agent doesn't have to know the state machine.

/// Read-only diagnostics for an app's current App Store review submission.
public struct AppStoreSubmissionService: Sendable {
    private let client: AppStoreConnectClient
    private let logger = Logger.forType(subsystem: "AppStoreConnectKit", AppStoreSubmissionService.self)

    /// Creates an `AppStoreSubmissionService` bound to an ASC client.
    public init(client: AppStoreConnectClient) {
        self.client = client
    }

    /// A normalized snapshot of where an app's latest App Store version stands in review.
    public struct SubmissionStatusReport: Codable, Sendable {
        /// App Store Connect app id.
        public let appID: String
        /// The bundle id used to resolve the app.
        public let bundleID: String
        /// The most recent App Store version, if any.
        public let latestVersion: VersionInfo?
        /// The most recent review submission for the app, if any.
        public let reviewSubmission: ReviewSubmissionInfo?
        /// Per-item outcomes for that review submission.
        public let items: [ReviewSubmissionItemInfo]
        /// `true` when the submission or any item needs the developer to act.
        public let needsDeveloperAction: Bool
        /// Plain-language explanation of the current state and the likely next step.
        public let diagnosis: String

        /// Creates a `SubmissionStatusReport`.
        public init(
            appID: String,
            bundleID: String,
            latestVersion: VersionInfo?,
            reviewSubmission: ReviewSubmissionInfo?,
            items: [ReviewSubmissionItemInfo],
            needsDeveloperAction: Bool,
            diagnosis: String
        ) {
            self.appID = appID
            self.bundleID = bundleID
            self.latestVersion = latestVersion
            self.reviewSubmission = reviewSubmission
            self.items = items
            self.needsDeveloperAction = needsDeveloperAction
            self.diagnosis = diagnosis
        }

        /// Minimal view of an `appStoreVersions` resource.
        public struct VersionInfo: Codable, Sendable {
            public let id: String
            public let versionString: String?
            public let platform: String?
            /// `appStoreState` / `appVersionState` — e.g. `REJECTED`, `WAITING_FOR_REVIEW`.
            public let state: String?
            public let createdDate: String?

            public init(id: String, versionString: String?, platform: String?, state: String?, createdDate: String?) {
                self.id = id
                self.versionString = versionString
                self.platform = platform
                self.state = state
                self.createdDate = createdDate
            }
        }

        /// Minimal view of a `reviewSubmissions` resource.
        public struct ReviewSubmissionInfo: Codable, Sendable {
            public let id: String
            /// `READY_FOR_REVIEW`, `WAITING_FOR_REVIEW`, `IN_REVIEW`, `UNRESOLVED_ISSUES`, `CANCELING`, `COMPLETING`, `COMPLETE`.
            public let state: String?
            public let platform: String?
            public let submittedDate: String?

            public init(id: String, state: String?, platform: String?, submittedDate: String?) {
                self.id = id
                self.state = state
                self.platform = platform
                self.submittedDate = submittedDate
            }
        }

        /// Minimal view of a `reviewSubmissionItems` resource.
        public struct ReviewSubmissionItemInfo: Codable, Sendable {
            public let id: String
            /// `READY_FOR_REVIEW`, `ACCEPTED`, `APPROVED`, `REJECTED`, `REMOVED`.
            public let state: String?

            public init(id: String, state: String?) {
                self.id = id
                self.state = state
            }
        }
    }

    /// Fetches the current submission status for the app with the given bundle id.
    ///
    /// - Parameter bundleID: The app's bundle identifier.
    /// - Returns: A ``SubmissionStatusReport``.
    /// - Throws: ``ASCError/apiError(statusCode:body:)`` if the app cannot be resolved.
    public func status(bundleID: String) async throws -> SubmissionStatusReport {
        let app = try await resolveApp(bundleID: bundleID)

        let versionResp: ASCListResponse<AppStoreVersionResource> = try await client.get(
            "/v1/apps/\(app.id)/appStoreVersions",
            query: ["limit": "1"]
        )
        let version = versionResp.data.first.map { resource in
            SubmissionStatusReport.VersionInfo(
                id: resource.id,
                versionString: resource.attributes?.versionString,
                platform: resource.attributes?.platform,
                state: resource.attributes?.appStoreState ?? resource.attributes?.appVersionState,
                createdDate: resource.attributes?.createdDate
            )
        }

        let submissionResp: ASCListResponse<ReviewSubmissionResource> = try await client.get(
            "/v1/reviewSubmissions",
            query: ["filter[app]": app.id, "limit": "1", "sort": "-submittedDate"]
        )
        let submissionResource = submissionResp.data.first
        let submission = submissionResource.map { resource in
            SubmissionStatusReport.ReviewSubmissionInfo(
                id: resource.id,
                state: resource.attributes?.state,
                platform: resource.attributes?.platform,
                submittedDate: resource.attributes?.submittedDate
            )
        }

        var items: [SubmissionStatusReport.ReviewSubmissionItemInfo] = []
        if let submissionID = submissionResource?.id {
            let itemsResp: ASCListResponse<ReviewSubmissionItemResource> = try await client.get(
                "/v1/reviewSubmissions/\(submissionID)/items",
                query: ["limit": "50"]
            )
            items = itemsResp.data.map { resource in
                SubmissionStatusReport.ReviewSubmissionItemInfo(id: resource.id, state: resource.attributes?.state)
            }
        }

        let needsAction = Self.needsDeveloperAction(
            versionState: version?.state,
            submissionState: submission?.state,
            itemStates: items.compactMap(\.state)
        )
        let diagnosis = Self.diagnose(
            versionString: version?.versionString,
            versionState: version?.state,
            submissionState: submission?.state,
            itemStates: items.compactMap(\.state)
        )

        logger.info(
            "Submission status for '\(bundleID)': version=\(version?.state ?? "none") submission=\(submission?.state ?? "none")"
        )

        return SubmissionStatusReport(
            appID: app.id,
            bundleID: bundleID,
            latestVersion: version,
            reviewSubmission: submission,
            items: items,
            needsDeveloperAction: needsAction,
            diagnosis: diagnosis
        )
    }

    // MARK: - State interpretation

    /// App Store version states that mean the ball is in the developer's court.
    static let developerActionVersionStates: Set<String> = [
        "REJECTED", "METADATA_REJECTED", "DEVELOPER_REJECTED", "INVALID_BINARY",
        "PENDING_DEVELOPER_RELEASE", "PREPARE_FOR_SUBMISSION",
    ]

    static func needsDeveloperAction(
        versionState: String?,
        submissionState: String?,
        itemStates: [String]
    ) -> Bool {
        if let versionState, developerActionVersionStates.contains(versionState.uppercased()) { return true }
        if submissionState?.uppercased() == "UNRESOLVED_ISSUES" { return true }
        if itemStates.contains(where: { $0.uppercased() == "REJECTED" }) { return true }
        return false
    }

    static func diagnose(
        versionString: String?,
        versionState: String?,
        submissionState: String?,
        itemStates: [String]
    ) -> String {
        let versionLabel = versionString.map { "Version \($0)" } ?? "The latest version"
        let vState = versionState?.uppercased() ?? ""
        let sState = submissionState?.uppercased() ?? ""

        switch (vState, sState) {
        case (_, "UNRESOLVED_ISSUES"), ("REJECTED", _):
            return
                "\(versionLabel) was REJECTED by App Review. Open Resolution Center in App Store Connect for the "
                + "reviewer's message, address the cited issues, then create a new review submission."
        case ("METADATA_REJECTED", _):
            return
                "\(versionLabel) was METADATA_REJECTED — the binary is fine but the store listing (screenshots, "
                + "description, keywords, support/marketing URLs, or age rating) needs changes. Fix the metadata and resubmit; no new build required."
        case ("DEVELOPER_REJECTED", _):
            return "\(versionLabel) was withdrawn by the developer (DEVELOPER_REJECTED). Make your changes and submit again when ready."
        case ("INVALID_BINARY", _):
            return
                "\(versionLabel) has an INVALID_BINARY — the uploaded build failed processing (bad entitlements, "
                + "missing icons, unsupported architecture, or an expired provisioning profile). Upload a corrected build and attach it to the version."
        case ("IN_REVIEW", _), (_, "IN_REVIEW"):
            return "\(versionLabel) is IN_REVIEW. No action needed — wait for Apple. Typical turnaround is 24–48h."
        case ("WAITING_FOR_REVIEW", _), (_, "WAITING_FOR_REVIEW"):
            return "\(versionLabel) is WAITING_FOR_REVIEW — queued at Apple. No action needed."
        case ("PENDING_DEVELOPER_RELEASE", _):
            return "\(versionLabel) is APPROVED and PENDING_DEVELOPER_RELEASE — release it manually from App Store Connect when ready."
        case ("PREPARE_FOR_SUBMISSION", _), ("", ""):
            return
                "\(versionLabel) is still in PREPARE_FOR_SUBMISSION and has not been submitted. Finish the metadata, "
                + "attach a build, and create a review submission."
        default:
            let itemNote =
                itemStates.isEmpty ? "" : " Submission items: \(itemStates.joined(separator: ", "))."
            return
                "\(versionLabel): version state = \(versionState ?? "unknown"), submission state = \(submissionState ?? "none")."
                + itemNote
        }
    }

    // MARK: - Private

    private func resolveApp(bundleID: String) async throws -> ASCApp {
        let apps: ASCListResponse<ASCApp> = try await client.get(
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

// MARK: - Wire resources (kept file-private; only the normalized report is public)

private struct AppStoreVersionResource: Codable, Sendable {
    let id: String
    let attributes: Attributes?

    struct Attributes: Codable, Sendable {
        let versionString: String?
        let platform: String?
        let appStoreState: String?
        let appVersionState: String?
        let createdDate: String?
    }
}

private struct ReviewSubmissionResource: Codable, Sendable {
    let id: String
    let attributes: Attributes?

    struct Attributes: Codable, Sendable {
        let state: String?
        let platform: String?
        let submittedDate: String?
    }
}

private struct ReviewSubmissionItemResource: Codable, Sendable {
    let id: String
    let attributes: Attributes?

    struct Attributes: Codable, Sendable {
        let state: String?
    }
}
