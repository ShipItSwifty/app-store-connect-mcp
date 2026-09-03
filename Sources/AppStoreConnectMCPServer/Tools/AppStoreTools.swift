import AppStoreConnectKit
import Foundation
import MCP

/// The App Store / TestFlight side of the tool catalog.
///
/// `CITools` answers "what broke in CI"; these answer everything an agent needs
/// *around* that — which app is this, did the build process, can testers see it,
/// what are customers saying — plus a raw passthrough for the parts of the API this
/// package has no typed model for.
///
/// Kept in its own list only for file size; ``CITools/specs`` concatenates it, so
/// there is still exactly one catalog the server advertises and dispatches from.
enum AppStoreTools {
    static let specs: [ToolSpec] = [
        ToolSpec(
            name: "asc_list_apps",
            description: """
                List the apps this API key can see, with their App Store Connect app id, \
                bundle id, name, SKU, and primary locale. Start here: every other app tool \
                needs either an app id or a bundle id, and this is the only way to discover them. \
                Optionally filter by exact bundle id or exact name.
                """,
            arguments: [
                .string("bundle_id", "Exact bundle identifier to filter by (optional)."),
                .string("name", "Exact app name to filter by (optional)."),
                .integer("limit", "Max apps to return (default 200)."),
            ]
        ) { args, makeClient in
            try json(
                await makeClient().apps(
                    bundleID: args.string("bundle_id"),
                    name: args.string("name"),
                    limit: args.int("limit", default: 200)
                ))
        },

        ToolSpec(
            name: "asc_list_app_store_versions",
            description: """
                List an app's App Store versions, newest first: version string, platform, \
                review state (PREPARE_FOR_SUBMISSION / WAITING_FOR_REVIEW / IN_REVIEW / \
                REJECTED / READY_FOR_DISTRIBUTION / …), release type, and creation date. \
                Pass either app_id or bundle_id. For *why* a version is stuck, use \
                asc_submission_status.
                """,
            arguments: [
                .string("app_id", "App Store Connect app id (or pass bundle_id)."),
                .string("bundle_id", "Bundle identifier, resolved to an app id."),
                .string("platform", "Filter by platform: IOS, MAC_OS, TV_OS, VISION_OS."),
                .integer("limit", "Max versions to return (default 20)."),
            ]
        ) { args, makeClient in
            let client = try makeClient()
            return try json(
                await client.appStoreVersions(
                    appID: try await resolveAppID(args, client: client),
                    platform: args.string("platform"),
                    limit: args.int("limit", default: 20)
                ))
        },

        ToolSpec(
            name: "asc_get_version_metadata",
            description: """
                Read the store-listing text of one App Store version, per locale: description, \
                keywords, what's new, promotional text, marketing and support URLs. Use the \
                version id from asc_list_app_store_versions or asc_submission_status.
                """,
            arguments: [
                .string("version_id", "App Store version id.", required: true),
                .integer("limit", "Max locales to return (default 200)."),
            ]
        ) { args, makeClient in
            try json(
                await makeClient().appStoreVersionLocalizations(
                    versionID: args.require("version_id"),
                    limit: args.int("limit", default: 200)
                ))
        },

        ToolSpec(
            name: "asc_list_builds",
            description: """
                List an app's uploaded builds, newest first: build number, processing state \
                (PROCESSING / VALID / FAILED / INVALID), upload and expiry dates, minimum OS, \
                buildAudienceType, and the export-compliance answer. Pass either app_id or \
                bundle_id. A null usesNonExemptEncryption means export compliance is \
                unanswered, which blocks both TestFlight external testing and submission; \
                an INTERNAL_ONLY buildAudienceType can never be attached to an App Store version.
                """,
            arguments: [
                .string("app_id", "App Store Connect app id (or pass bundle_id)."),
                .string("bundle_id", "Bundle identifier, resolved to an app id."),
                .string("version", "Filter to one build number (CFBundleVersion)."),
                .string("pre_release_version", "Filter to one marketing version (CFBundleShortVersionString)."),
                .string("processing_state", "Filter by processing state: PROCESSING, FAILED, INVALID, VALID."),
                .integer("limit", "Max builds to return (default 20)."),
            ]
        ) { args, makeClient in
            let client = try makeClient()
            return try json(
                await client.builds(
                    appID: try await resolveAppID(args, client: client),
                    version: args.string("version"),
                    preReleaseVersion: args.string("pre_release_version"),
                    processingState: args.string("processing_state"),
                    limit: args.int("limit", default: 20)
                ))
        },

        ToolSpec(
            name: "asc_testflight_build_status",
            description: """
                Diagnose why a build is or isn't available to TestFlight testers. Returns the \
                newest build (or the one named by version) together with its internal and \
                external beta states (WAITING_FOR_BETA_REVIEW, IN_BETA_REVIEW, REJECTED, \
                IN_EXPORT_COMPLIANCE_REVIEW, READY_FOR_TESTING, …) and its per-locale \
                "What to Test" notes. Pass either app_id or bundle_id.
                """,
            arguments: [
                .string("app_id", "App Store Connect app id (or pass bundle_id)."),
                .string("bundle_id", "Bundle identifier, resolved to an app id."),
                .string("version", "Build number to inspect. Defaults to the newest build."),
            ]
        ) { args, makeClient in
            let client = try makeClient()
            let appID = try await resolveAppID(args, client: client)
            let builds = try await client.builds(appID: appID, version: args.string("version"), limit: 1)
            guard let build = builds.data.first else {
                return try json(TestFlightBuildStatus(found: false, build: nil, betaDetail: nil, whatToTest: []))
            }
            // Both hang off the same build and neither depends on the other.
            async let detail = client.buildBetaDetail(buildID: build.id)
            async let localizations = client.betaBuildLocalizations(buildID: build.id)
            return try json(
                TestFlightBuildStatus(
                    found: true,
                    build: build,
                    betaDetail: try await detail.data,
                    whatToTest: try await localizations.data
                ))
        },

        ToolSpec(
            name: "asc_list_beta_groups",
            description: """
                List an app's TestFlight beta groups: name, internal vs external, public link \
                and its redemption cap, whether feedback is enabled, and whether the group \
                automatically receives every build. Pass either app_id or bundle_id.
                """,
            arguments: [
                .string("app_id", "App Store Connect app id (or pass bundle_id)."),
                .string("bundle_id", "Bundle identifier, resolved to an app id."),
                .integer("limit", "Max groups to return (default 200)."),
            ]
        ) { args, makeClient in
            let client = try makeClient()
            return try json(
                await client.betaGroups(
                    appID: try await resolveAppID(args, client: client),
                    limit: args.int("limit", default: 200)
                ))
        },

        ToolSpec(
            name: "asc_list_beta_testers",
            description: """
                List the testers in one TestFlight beta group, with each tester's invite type \
                and state (INVITED / ACCEPTED / INSTALLED / NOT_INVITED / REVOKED).
                """,
            arguments: [
                .string("beta_group_id", "Beta group id (from asc_list_beta_groups).", required: true),
                .integer("limit", "Max testers to return (default 200)."),
            ]
        ) { args, makeClient in
            try json(
                await makeClient().betaTesters(
                    betaGroupID: args.require("beta_group_id"),
                    limit: args.int("limit", default: 200)
                ))
        },

        ToolSpec(
            name: "asc_list_beta_feedback",
            description: """
                List TestFlight tester feedback for an app, newest first — crash submissions \
                (with device model, OS version, battery, disk and uptime at the time of the \
                crash) or screenshot submissions (with the tester's comment and time-limited \
                image URLs). This is the closest thing to a bug report from a real user; use \
                it to correlate a spike in complaints with a specific build or device. \
                Pass either app_id or bundle_id.
                """,
            arguments: [
                .string("app_id", "App Store Connect app id (or pass bundle_id)."),
                .string("bundle_id", "Bundle identifier, resolved to an app id."),
                .string("kind", "'crash' (default) or 'screenshot'."),
                .string("build_id", "Restrict to one build id (from asc_list_builds)."),
                .string("device_model", "Restrict to one device model, e.g. iPhone14,3."),
                .string("os_version", "Restrict to one OS version, e.g. 18.2."),
                .integer("limit", "Max submissions to return (default 50)."),
            ]
        ) { args, makeClient in
            let raw = (args.string("kind") ?? "crash").lowercased()
            guard let kind = AppStoreConnectClient.BetaFeedbackKind(rawValue: raw) else {
                throw ASCError.invalidConfiguration(
                    reason: "Unknown feedback kind '\(raw)'. Use 'crash' or 'screenshot'."
                )
            }
            let client = try makeClient()
            return try json(
                await client.betaFeedback(
                    appID: try await resolveAppID(args, client: client),
                    kind: kind,
                    buildID: args.string("build_id"),
                    deviceModel: args.string("device_model"),
                    osVersion: args.string("os_version"),
                    limit: args.int("limit", default: 50)
                ))
        },

        ToolSpec(
            name: "asc_list_customer_reviews",
            description: """
                List an app's App Store customer reviews, newest first: star rating, title, \
                body, reviewer nickname, storefront, and date. Filter by rating or territory \
                to pull, say, every 1-star review from the US since a release. Pass either \
                app_id or bundle_id.
                """,
            arguments: [
                .string("app_id", "App Store Connect app id (or pass bundle_id)."),
                .string("bundle_id", "Bundle identifier, resolved to an app id."),
                .integer("rating", "Restrict to one star rating, 1-5."),
                .string("territory", "Restrict to one storefront, ISO 3166-1 alpha-3 (e.g. USA)."),
                .integer("limit", "Max reviews to return (default 50)."),
            ]
        ) { args, makeClient in
            let client = try makeClient()
            let rating = args.int("rating", default: 0, max: 5)
            return try json(
                await client.customerReviews(
                    appID: try await resolveAppID(args, client: client),
                    rating: rating > 0 ? rating : nil,
                    territory: args.string("territory"),
                    limit: args.int("limit", default: 50)
                ))
        },

        ToolSpec(
            name: "asc_rate_limit_status",
            description: """
                Report this key's current App Store Connect hourly rate-limit position: the \
                limit, requests remaining, percentage used, and the threshold at which this \
                server starts pausing requests. Costs one cheap request. Check it before a \
                broad scan. Returns {"known": false} until a first response has been seen.
                """
        ) { _, makeClient in
            let client = try makeClient()
            // The limit is only known from a response header, so make the cheapest call
            // there is (a single-app page) purely to learn the current position.
            _ = try? await client.apps(limit: 1)
            guard let status = await client.rateLimiter.status() else {
                return try json(RateLimitReport(known: false, status: nil))
            }
            return try json(RateLimitReport(known: true, status: status))
        },

        ToolSpec(
            name: "asc_api_get",
            description: """
                Escape hatch: perform an arbitrary authenticated GET against the App Store \
                Connect API and return Apple's JSON verbatim. Use this for resources the typed \
                tools above don't cover — appInfos, appPrices, inAppPurchases, subscriptions, \
                appEvents, users, devices, certificates, profiles, salesReports metadata, and \
                anything Apple adds later. Give a path such as \
                '/v1/apps/123/appInfos?include=primaryCategory&limit=5'; the query string may \
                be inline or supplied via the 'query' argument as a JSON object. Only GET is \
                possible — this tool cannot modify anything. Returns one page: follow \
                'links.next' by passing it back as the path.
                """,
            arguments: [
                .string(
                    "path",
                    "API path beginning with /v1/ or /v2/ (a full https://api.appstoreconnect.apple.com URL "
                        + "is also accepted, so links.next can be pasted straight back).",
                    required: true
                ),
                .string("query", "Optional query parameters as a JSON object, e.g. {\"limit\":\"5\"}."),
            ]
        ) { args, makeClient in
            let (path, inlineQuery) = try parseAPIPath(args.require("path"))
            let query = try inlineQuery.merging(parseQueryObject(args.string("query"))) { _, explicit in explicit }
            let data = try await makeClient().getRaw(path, query: query)
            return .init(content: [.plainText(prettyPrinted(data))], isError: false)
        },
    ]

    // MARK: - Payloads

    /// `asc_testflight_build_status` payload.
    private struct TestFlightBuildStatus: Encodable {
        let found: Bool
        let build: ASCBuild?
        let betaDetail: ASCBuildBetaDetail?
        let whatToTest: [ASCBetaBuildLocalization]
    }

    /// `asc_rate_limit_status` payload.
    private struct RateLimitReport: Encodable {
        let known: Bool
        let status: RateLimitStatus?
    }

    // MARK: - Helpers

    /// Resolves the `app_id` / `bundle_id` pair every app-scoped tool accepts.
    ///
    /// An agent that has only a bundle id shouldn't have to make a discovery call first,
    /// and one that already has an app id shouldn't pay for a lookup it doesn't need.
    private static func resolveAppID(_ args: ToolArguments, client: AppStoreConnectClient) async throws -> String {
        if let appID = args.string("app_id") { return appID }
        guard let bundleID = args.string("bundle_id") else {
            throw ASCError.invalidConfiguration(reason: "Pass either 'app_id' or 'bundle_id'.")
        }
        let apps = try await client.apps(bundleID: bundleID, limit: 1)
        guard let app = apps.data.first else {
            throw ASCError.apiError(
                statusCode: 404,
                body: "No app with bundle id '\(bundleID)' is visible to this API key."
            )
        }
        return app.id
    }

    /// Splits a caller-supplied path into a path and its inline query, rejecting
    /// anything that is not an App Store Connect API path.
    ///
    /// A full `https://api.appstoreconnect.apple.com/...` URL is accepted so a
    /// `links.next` value can be pasted straight back in.
    static func parseAPIPath(_ raw: String) throws -> (path: String, query: [String: String]) {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://api.appstoreconnect.apple.com", "http://api.appstoreconnect.apple.com"] {
            if value.hasPrefix(prefix) { value.removeFirst(prefix.count) }
        }
        guard value.hasPrefix("/v1/") || value.hasPrefix("/v2/") else {
            throw ASCError.invalidConfiguration(
                reason: "Path must begin with /v1/ or /v2/ (got '\(raw)')."
            )
        }
        guard let components = URLComponents(string: value) else {
            throw ASCError.invalidConfiguration(reason: "Could not parse path '\(raw)'.")
        }
        let query = (components.queryItems ?? []).reduce(into: [String: String]()) { result, item in
            result[item.name] = item.value ?? ""
        }
        return (components.path, query)
    }

    /// Parses the optional `query` argument, a JSON object of string values.
    static func parseQueryObject(_ raw: String?) throws -> [String: String] {
        guard let raw else { return [:] }
        guard let data = raw.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw ASCError.invalidConfiguration(reason: "'query' must be a JSON object of query parameters.")
        }
        return object.reduce(into: [String: String]()) { result, pair in
            switch pair.value {
            case let string as String: result[pair.key] = string
            case let number as NSNumber: result[pair.key] = number.stringValue
            default: result[pair.key] = String(describing: pair.value)
            }
        }
    }

    /// Re-formats a raw JSON body for readability, passing it through unchanged if it
    /// is not JSON after all.
    static func prettyPrinted(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data),
            let pretty = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
        else { return String(decoding: data, as: UTF8.self) }
        return String(decoding: pretty, as: UTF8.self)
    }

    private static func json<T: Encodable>(_ value: T) throws -> CallTool.Result {
        try CITools.json(value)
    }
}
