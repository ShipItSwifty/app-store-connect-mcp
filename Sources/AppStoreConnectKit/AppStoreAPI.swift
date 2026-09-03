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
