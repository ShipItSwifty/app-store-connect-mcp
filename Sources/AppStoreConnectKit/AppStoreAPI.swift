import Foundation

// MARK: - App Store & TestFlight read API
//
// Thin, typed convenience methods over the generic `getAll` / `get` on
// `AppStoreConnectClient`, covering the resources an agent needs to answer the
// questions that aren't about CI: *which app is this*, *did the build process*,
// *can testers see it*, *what are people saying about it*.
//
// All are read-only and paged through `getAll`, so a caller cannot silently
// truncate at one page.

extension AppStoreConnectClient {
    /// Lists the apps visible to this API key.
    ///
    /// This is the entry point for everything else here: every other call needs an
    /// app id, and an agent starts with nothing but a name or a bundle id.
    ///
    /// - Parameters:
    ///   - bundleID: Exact `filter[bundleId]` match. Pass `nil` for all apps.
    ///   - name: Exact `filter[name]` match.
    ///   - limit: Maximum apps to return across all pages.
    public func apps(
        bundleID: String? = nil,
        name: String? = nil,
        limit: Int = 200
    ) async throws -> ASCListResponse<ASCApp> {
        var query: [String: String] = [:]
        if let bundleID { query["filter[bundleId]"] = bundleID }
        if let name { query["filter[name]"] = name }
        return try await getAll("/v1/apps", query: query, limit: limit)
    }

    /// Fetches a single app by App Store Connect id.
    public func app(id: String) async throws -> ASCResponse<ASCApp> {
        try await get("/v1/apps/\(id)")
    }

    // MARK: - App Store versions

    /// Lists an app's App Store versions, newest first.
    ///
    /// - Parameters:
    ///   - appID: App Store Connect app id.
    ///   - platform: Optional `filter[platform]` (`IOS`, `MAC_OS`, `TV_OS`, `VISION_OS`).
    ///   - limit: Maximum versions to return across all pages.
    public func appStoreVersions(
        appID: String,
        platform: String? = nil,
        limit: Int = 20
    ) async throws -> ASCListResponse<ASCAppStoreVersion> {
        // `/v1/apps/{id}/appStoreVersions` does not accept `sort`; the collection is
        // returned newest-first already, so no client-side ordering is applied.
        var query: [String: String] = [:]
        if let platform { query["filter[platform]"] = platform }
        return try await getAll("/v1/apps/\(appID)/appStoreVersions", query: query, limit: limit)
    }

    /// Lists the store-listing text (description, keywords, what's new, …) of an App
    /// Store version, one resource per locale.
    public func appStoreVersionLocalizations(
        versionID: String,
        limit: Int = 200
    ) async throws -> ASCListResponse<ASCAppStoreVersionLocalization> {
        try await getAll("/v1/appStoreVersions/\(versionID)/appStoreVersionLocalizations", limit: limit)
    }

    // MARK: - Builds

    /// Lists an app's builds, newest upload first.
    ///
    /// Uses `/v1/builds` rather than `/v1/apps/{id}/builds` because only the former
    /// accepts `sort` — the nested collection would come back in an unspecified order.
    ///
    /// - Parameters:
    ///   - appID: App Store Connect app id.
    ///   - version: Optional `filter[version]` — the build number (`CFBundleVersion`).
    ///   - preReleaseVersion: Optional `filter[preReleaseVersion.version]` — the marketing
    ///     version (`CFBundleShortVersionString`) the build belongs to.
    ///   - processingState: Optional `filter[processingState]` (`PROCESSING`, `FAILED`,
    ///     `INVALID`, `VALID`).
    ///   - limit: Maximum builds to return across all pages.
    public func builds(
        appID: String,
        version: String? = nil,
        preReleaseVersion: String? = nil,
        processingState: String? = nil,
        limit: Int = 20
    ) async throws -> ASCListResponse<ASCBuild> {
        var query: [String: String] = ["filter[app]": appID, "sort": "-uploadedDate"]
        if let version { query["filter[version]"] = version }
        if let preReleaseVersion { query["filter[preReleaseVersion.version]"] = preReleaseVersion }
        if let processingState { query["filter[processingState]"] = processingState }
        return try await getAll("/v1/builds", query: query, limit: limit)
    }

    /// Reads a build's TestFlight distribution state — the answer to "the build
    /// uploaded fine, so why can't my testers install it?".
    public func buildBetaDetail(buildID: String) async throws -> ASCResponse<ASCBuildBetaDetail> {
        try await get("/v1/builds/\(buildID)/buildBetaDetail")
    }

    /// Lists a build's "What to Test" notes, one resource per locale.
    public func betaBuildLocalizations(
        buildID: String,
        limit: Int = 200
    ) async throws -> ASCListResponse<ASCBetaBuildLocalization> {
        try await getAll("/v1/builds/\(buildID)/betaBuildLocalizations", limit: limit)
    }

    // MARK: - TestFlight groups & testers

    /// Lists an app's TestFlight beta groups.
    public func betaGroups(appID: String, limit: Int = 200) async throws -> ASCListResponse<ASCBetaGroup> {
        try await getAll("/v1/apps/\(appID)/betaGroups", limit: limit)
    }

    /// Lists the testers in a beta group.
    public func betaTesters(betaGroupID: String, limit: Int = 200) async throws -> ASCListResponse<ASCBetaTester> {
        try await getAll("/v1/betaGroups/\(betaGroupID)/betaTesters", limit: limit)
    }

    // MARK: - TestFlight feedback

    /// The two kinds of TestFlight feedback a tester can submit.
    public enum BetaFeedbackKind: String, Sendable, CaseIterable {
        /// A crash the tester's device reported, with device state at the time.
        case crash
        /// A screenshot the tester sent, usually with a comment.
        case screenshot

        var path: String {
            switch self {
            case .crash: "betaFeedbackCrashSubmissions"
            case .screenshot: "betaFeedbackScreenshotSubmissions"
            }
        }
    }

    /// Lists TestFlight feedback submissions for an app, newest first.
    ///
    /// - Parameters:
    ///   - appID: App Store Connect app id.
    ///   - kind: Crash reports or screenshot feedback.
    ///   - buildID: Optional `filter[build]` — restrict to one build.
    ///   - deviceModel: Optional `filter[deviceModel]` (e.g. `iPhone14,3`).
    ///   - osVersion: Optional `filter[osVersion]`.
    ///   - limit: Maximum submissions to return across all pages.
    public func betaFeedback(
        appID: String,
        kind: BetaFeedbackKind,
        buildID: String? = nil,
        deviceModel: String? = nil,
        osVersion: String? = nil,
        limit: Int = 50
    ) async throws -> ASCListResponse<ASCBetaFeedback> {
        var query: [String: String] = ["sort": "-createdDate"]
        if let buildID { query["filter[build]"] = buildID }
        if let deviceModel { query["filter[deviceModel]"] = deviceModel }
        if let osVersion { query["filter[osVersion]"] = osVersion }
        return try await getAll("/v1/apps/\(appID)/\(kind.path)", query: query, limit: limit)
    }

    // MARK: - Review readiness

    /// Reads a version's staged-rollout state, or `nil` when the version has no phased
    /// release (the default for a manual or immediate release).
    public func phasedRelease(versionID: String) async throws -> ASCPhasedRelease? {
        try await optionalResource("/v1/appStoreVersions/\(versionID)/appStoreVersionPhasedRelease")
    }

    /// Reads the contact and demo-account details App Review sees for a version.
    public func appStoreReviewDetail(versionID: String) async throws -> ASCReviewDetail? {
        try await optionalResource("/v1/appStoreVersions/\(versionID)/appStoreReviewDetail")
    }

    /// Reads the contact and demo-account details Beta App Review sees for an app.
    public func betaAppReviewDetail(appID: String) async throws -> ASCReviewDetail? {
        try await optionalResource("/v1/apps/\(appID)/betaAppReviewDetail")
    }

    /// Lists an app's `appInfos` — the app-level listing records, whose state is
    /// reviewed separately from any one version.
    public func appInfos(appID: String, limit: Int = 10) async throws -> ASCListResponse<ASCAppInfo> {
        try await getAll("/v1/apps/\(appID)/appInfos", limit: limit)
    }

    // MARK: - Signing assets

    /// Lists the team's signing certificates, soonest expiry first.
    public func certificates(limit: Int = 200) async throws -> ASCListResponse<ASCCertificate> {
        try await getAll("/v1/certificates", query: ["sort": "expirationDate"], limit: limit)
    }

    /// Lists the team's provisioning profiles.
    ///
    /// - Parameter state: Optional `filter[profileState]` — `ACTIVE` or `INVALID`.
    public func profiles(state: String? = nil, limit: Int = 200) async throws -> ASCListResponse<ASCProfile> {
        var query: [String: String] = [:]
        if let state { query["filter[profileState]"] = state }
        return try await getAll("/v1/profiles", query: query, limit: limit)
    }

    /// Lists certificates and profiles together, flagging the ones that will break
    /// signing — already expired, expiring within `withinDays`, or marked `INVALID`.
    ///
    /// "It built last week and fails today" is nearly always one of those three, and
    /// checking each collection by hand is three calls and a date comparison.
    public func signingAssets(withinDays: Int = 30, limit: Int = 200) async throws -> SigningAssetsReport {
        async let certificatesTask = certificates(limit: limit)
        async let profilesTask = profiles(limit: limit)
        let certificates = try await certificatesTask.data
        let profiles = try await profilesTask.data

        let now = Date()
        func daysRemaining(_ date: String?) -> Int? {
            guard let expiry = CIDate.parse(date) else { return nil }
            return Int((expiry.timeIntervalSince(now) / 86400).rounded(.down))
        }

        var expiring: [SigningAssetsReport.Expiring] = []
        for certificate in certificates {
            guard let days = daysRemaining(certificate.attributes?.expirationDate), days <= withinDays else { continue }
            expiring.append(
                .init(
                    kind: "certificate",
                    id: certificate.id,
                    name: certificate.attributes?.displayName ?? certificate.attributes?.name,
                    expirationDate: certificate.attributes?.expirationDate,
                    daysRemaining: days
                ))
        }
        for profile in profiles {
            guard let days = daysRemaining(profile.attributes?.expirationDate), days <= withinDays else { continue }
            expiring.append(
                .init(
                    kind: "profile",
                    id: profile.id,
                    name: profile.attributes?.name,
                    expirationDate: profile.attributes?.expirationDate,
                    daysRemaining: days
                ))
        }

        return SigningAssetsReport(
            certificates: certificates,
            profiles: profiles,
            expiringSoon: expiring.sorted { ($0.daysRemaining ?? 0) < ($1.daysRemaining ?? 0) },
            invalidProfiles:
                profiles
                .filter { ($0.attributes?.profileState ?? "").uppercased() == "INVALID" }
                .map { $0.attributes?.name ?? $0.id }
        )
    }

    /// Reads a to-one relationship that App Store Connect answers with a 404 when it
    /// is not set — "no phased release configured", "no review detail filled in" — which
    /// is an answer rather than a failure.
    private func optionalResource<T: Codable & Sendable>(_ path: String) async throws -> T? {
        do {
            let response: ASCResponse<T> = try await get(path)
            return response.data
        } catch let error as ASCError {
            if case .apiError(let statusCode, _) = error, statusCode == 404 { return nil }
            throw error
        }
    }

    // MARK: - Customer reviews

    /// Lists an app's App Store customer reviews, newest first.
    ///
    /// - Parameters:
    ///   - appID: App Store Connect app id.
    ///   - rating: Optional `filter[rating]` (`1`–`5`).
    ///   - territory: Optional `filter[territory]` — ISO 3166-1 alpha-3 (e.g. `USA`).
    ///   - limit: Maximum reviews to return across all pages.
    public func customerReviews(
        appID: String,
        rating: Int? = nil,
        territory: String? = nil,
        limit: Int = 50
    ) async throws -> ASCListResponse<ASCCustomerReview> {
        var query: [String: String] = ["sort": "-createdDate"]
        if let rating { query["filter[rating]"] = String(rating) }
        if let territory { query["filter[territory]"] = territory }
        return try await getAll("/v1/apps/\(appID)/customerReviews", query: query, limit: limit)
    }
}
