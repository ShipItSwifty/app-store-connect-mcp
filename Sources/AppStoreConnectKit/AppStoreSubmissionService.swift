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
        /// Whether a pre-release build is attached to the latest version.
        ///
        /// `nil` when there is no latest version to inspect. A version stuck in
        /// `PREPARE_FOR_SUBMISSION` with no build attached is a common "can't submit"
        /// cause that the `reviewSubmissions` resource never surfaces.
        public let buildAttached: Bool?
        /// The build attached to the latest version, when one is attached.
        public let attachedBuild: BuildInfo?
        /// The newest build the app has for the latest version's `versionString`, if any.
        ///
        /// Populated only when no build is attached, so the caller can see whether a
        /// valid candidate exists (and therefore that the blocker is the attachment
        /// itself, not a missing build).
        public let candidateBuild: BuildInfo?

        /// Creates a `SubmissionStatusReport`.
        public init(
            appID: String,
            bundleID: String,
            latestVersion: VersionInfo?,
            reviewSubmission: ReviewSubmissionInfo?,
            items: [ReviewSubmissionItemInfo],
            needsDeveloperAction: Bool,
            diagnosis: String,
            buildAttached: Bool? = nil,
            attachedBuild: BuildInfo? = nil,
            candidateBuild: BuildInfo? = nil
        ) {
            self.appID = appID
            self.bundleID = bundleID
            self.latestVersion = latestVersion
            self.reviewSubmission = reviewSubmission
            self.items = items
            self.needsDeveloperAction = needsDeveloperAction
            self.diagnosis = diagnosis
            self.buildAttached = buildAttached
            self.attachedBuild = attachedBuild
            self.candidateBuild = candidateBuild
        }

        /// Minimal view of a `builds` resource.
        public struct BuildInfo: Codable, Sendable {
            public let id: String
            /// The build (CFBundleVersion) string, e.g. `"142"`.
            public let version: String?
            /// `PROCESSING`, `VALID`, `FAILED`, `INVALID`.
            public let processingState: String?
            /// Whether the build has expired.
            public let expired: Bool?

            public init(id: String, version: String?, processingState: String?, expired: Bool?) {
                self.id = id
                self.version = version
                self.processingState = processingState
                self.expired = expired
            }
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
        let app = try await client.app(bundleID: bundleID)

        let versionResp: ASCListResponse<AppStoreVersionResource> = try await client.get(
            "/v1/apps/\(app.id)/appStoreVersions",
            query: ["limit": "1"]
        )
        let versionResource = versionResp.data.first
        let version = versionResource.map { resource in
            SubmissionStatusReport.VersionInfo(
                id: resource.id,
                versionString: resource.attributes?.versionString,
                platform: resource.attributes?.platform,
                state: resource.state,
                createdDate: resource.attributes?.createdDate
            )
        }

        // `GET /v1/reviewSubmissions` does not accept a `sort` parameter — passing one is a
        // hard 400 (`PARAMETER_ERROR.ILLEGAL`). Fetch a recent page unsorted and choose the
        // latest submission client-side.
        let submissionResp: ASCListResponse<ReviewSubmissionResource> = try await client.get(
            "/v1/reviewSubmissions",
            query: ["filter[app]": app.id, "limit": "20"]
        )
        let submissionResource = Self.mostRecentSubmission(submissionResp.data)
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

        // Is a build attached to the latest version? A version stuck in
        // PREPARE_FOR_SUBMISSION with no build is a common "can't submit" cause that
        // `reviewSubmissions` never surfaces. When nothing is attached, also look up the
        // newest build for that version so the caller can tell "no build exists" from
        // "a valid build exists but won't attach".
        var buildAttached: Bool?
        var attachedBuild: SubmissionStatusReport.BuildInfo?
        var candidateBuild: SubmissionStatusReport.BuildInfo?
        if let versionResource {
            attachedBuild = try await Self.attachedBuild(client: client, versionID: versionResource.id)
            buildAttached = attachedBuild != nil
            if attachedBuild == nil, let versionString = versionResource.attributes?.versionString {
                candidateBuild = try await Self.newestBuild(
                    client: client,
                    appID: app.id,
                    versionString: versionString
                )
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
            itemStates: items.compactMap(\.state),
            buildAttached: buildAttached,
            candidateBuild: candidateBuild
        )

        logger.info(
            "Submission status for '\(bundleID)': version=\(version?.state ?? "none") submission=\(submission?.state ?? "none") buildAttached=\(buildAttached.map(String.init) ?? "n/a")"
        )

        return SubmissionStatusReport(
            appID: app.id,
            bundleID: bundleID,
            latestVersion: version,
            reviewSubmission: submission,
            items: items,
            needsDeveloperAction: needsAction,
            diagnosis: diagnosis,
            buildAttached: buildAttached,
            attachedBuild: attachedBuild,
            candidateBuild: candidateBuild
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

    /// Picks the most recent review submission from an unsorted page.
    ///
    /// `GET /v1/reviewSubmissions` has no `sort` parameter, so the page comes back in an
    /// arbitrary order. Order by `submittedDate` descending; a submission with no
    /// `submittedDate` (still being assembled / not yet submitted) counts as the newest.
    private static func mostRecentSubmission(
        _ resources: [ReviewSubmissionResource]
    ) -> ReviewSubmissionResource? {
        resources.max { lhs, rhs in
            submissionIsOlder(lhs, than: rhs)
        }
    }

    private static func submissionIsOlder(
        _ lhs: ReviewSubmissionResource,
        than rhs: ReviewSubmissionResource
    ) -> Bool {
        switch (lhs.attributes?.submittedDate, rhs.attributes?.submittedDate) {
        case (nil, _): return false
        case (_, nil): return true
        case (let lhsDate?, let rhsDate?): return lhsDate < rhsDate
        }
    }

    static func diagnose(
        versionString: String?,
        versionState: String?,
        submissionState: String?,
        itemStates: [String],
        buildAttached: Bool? = nil,
        candidateBuild: SubmissionStatusReport.BuildInfo? = nil
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
            if buildAttached == false {
                let candidateNote: String
                switch candidateBuild?.processingState?.uppercased() {
                case "VALID":
                    candidateNote =
                        " Build \(candidateBuild?.version ?? "?") exists for this version and is VALID, so a "
                        + "candidate is available — if it still won't attach in App Store Connect either, the cause is "
                        + "usually outside the App Store Connect API: an incomplete App Privacy (data-collection) "
                        + "section, a pending agreement in Agreements, Tax, and Banking, or unresolved export compliance."
                case .some(let state):
                    candidateNote =
                        " The newest build for this version (\(candidateBuild?.version ?? "?")) is \(state), not VALID — "
                        + "wait for processing to finish or upload a new build."
                case nil:
                    candidateNote =
                        " No build has been uploaded for this version yet — archive and upload one from Xcode, wait for "
                        + "it to finish processing, then attach it."
                }
                return
                    "\(versionLabel) is in PREPARE_FOR_SUBMISSION with no build selected. Attach a processed build to "
                    + "the version, finish the metadata, then create a review submission." + candidateNote
            }
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

    /// Returns the build attached to the given App Store version, or `nil` when none is set.
    ///
    /// `GET /v1/appStoreVersions/{id}/build` returns `{ "data": null }` (HTTP 200) when no
    /// build is attached; some tenants answer 404 instead, which is treated the same way.
    private static func attachedBuild(
        client: AppStoreConnectClient,
        versionID: String
    ) async throws -> SubmissionStatusReport.BuildInfo? {
        do {
            let resp: SingleBuildEnvelope = try await client.get("/v1/appStoreVersions/\(versionID)/build")
            return resp.data.map(Self.buildInfo)
        } catch let ASCError.apiError(statusCode, _) where statusCode == 404 {
            return nil
        }
    }

    /// Returns the newest build the app has for a given marketing version string, if any.
    ///
    /// `GET /v1/builds` does support `sort`, so ask for the most recently uploaded build
    /// filtered to this version's pre-release version.
    private static func newestBuild(
        client: AppStoreConnectClient,
        appID: String,
        versionString: String
    ) async throws -> SubmissionStatusReport.BuildInfo? {
        let resp: ASCListResponse<BuildResource> = try await client.get(
            "/v1/builds",
            query: [
                "filter[app]": appID,
                "filter[preReleaseVersion.version]": versionString,
                "sort": "-uploadedDate",
                "limit": "1",
            ]
        )
        return resp.data.first.map(Self.buildInfo)
    }

    private static func buildInfo(_ resource: BuildResource) -> SubmissionStatusReport.BuildInfo {
        SubmissionStatusReport.BuildInfo(
            id: resource.id,
            version: resource.attributes?.version,
            processingState: resource.attributes?.processingState,
            expired: resource.attributes?.expired
        )
    }
}

// MARK: - Wire resources
//
// The shared shapes live in `WireResources.swift`; only what is specific to this
// service is declared here.

/// `{ "data": <build> | null }` — the shape of `GET /v1/appStoreVersions/{id}/build`.
private struct SingleBuildEnvelope: Codable, Sendable {
    let data: BuildResource?
}
