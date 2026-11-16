import AppStoreConnectKit
import AppStoreConnectMCPSDK
import Foundation

/// The tools that change something in App Store Connect.
///
/// Everything else this server exposes is read-only, which is what lets a host
/// auto-approve a whole investigation. These are advertised **only** when
/// `ASC_ENABLE_WRITES` is set, so a default deployment keeps that property and an
/// operator opts in deliberately; a host that never sets it sees a catalog whose every
/// tool is `readOnlyHint: true`. When the variable is unset, calling one of these by
/// name returns an error saying how to enable it rather than "unknown tool".
///
/// Part of the single catalog; see ``CITools/specs``.
enum WriteTools {
    /// The environment variable that opts a deployment in to writes.
    static let enableVariable = "ASC_ENABLE_WRITES"

    /// Whether writes are enabled. Anything but `1`, `true`, or `yes` reads as off.
    static func isEnabled(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard let raw = environment[enableVariable]?.lowercased() else { return false }
        return ["1", "true", "yes"].contains(raw)
    }

    /// The message a disabled write tool answers with — it names the variable rather
    /// than leaving the caller to guess why a tool it can see refuses to run.
    static func disabledMessage(for name: String) -> String {
        """
        Tool '\(name)' changes App Store Connect and is disabled. Set \(enableVariable)=1 \
        in the server's environment to enable the write tools (\(specs.map(\.name).sorted().joined(separator: ", "))).
        """
    }

    static let specs: [ToolSpec] = [
        ToolSpec(
            name: "asc_ci_start_build",
            description: """
                Start an Xcode Cloud build for a workflow. Optionally build a specific branch \
                or tag (an scmGitReferences id) instead of the workflow's own start condition, \
                and optionally force a clean build. Returns the created build run — poll it \
                with asc_ci_get_build_run. THIS STARTS A REAL CI BUILD and consumes Xcode \
                Cloud compute minutes.
                """,
            arguments: [
                .string("workflow_id", "Xcode Cloud workflow id (from asc_ci_list_workflows).", required: true),
                .string("git_reference_id", "scmGitReferences id of the branch or tag to build (optional)."),
                .boolean("clean", "Force a clean build, discarding the derived-data cache."),
            ],
            isReadOnly: false
        ) { args, makeClient in
            try json(
                await makeClient().startCIBuildRun(
                    workflowID: args.require("workflow_id"),
                    gitReferenceID: args.string("git_reference_id"),
                    clean: args.bool("clean") ? true : nil
                ))
        },

        ToolSpec(
            name: "asc_ci_rerun_build",
            description: """
                Re-run an existing Xcode Cloud build run, reusing its workflow and git \
                reference so the retry builds the same commit — which a fresh workflow run \
                would not guarantee. Use this after asc_ci_latest_failure when the failure \
                looks flaky. THIS STARTS A REAL CI BUILD and consumes Xcode Cloud compute \
                minutes.
                """,
            arguments: [
                .string("build_run_id", "The build run to repeat.", required: true),
                .boolean("clean", "Force a clean build, discarding the derived-data cache."),
            ],
            isReadOnly: false
        ) { args, makeClient in
            try json(
                await makeClient().rerunCIBuildRun(
                    buildRunID: args.require("build_run_id"),
                    clean: args.bool("clean") ? true : nil
                ))
        },

        ToolSpec(
            name: "asc_update_whats_new",
            description: """
                Set the "What's New" release notes for one locale on the app's latest App \
                Store version. Fails if that version is already in review — a submitted \
                version cannot be edited. THIS CHANGES PUBLIC-FACING STORE METADATA.
                """,
            arguments: [
                .string("bundle_id", "The app's bundle identifier.", required: true),
                .string("locale", "Locale to update, e.g. en-US.", required: true),
                .string("text", "The release-notes text.", required: true),
            ],
            isReadOnly: false
        ) { args, makeClient in
            let service = AppStoreReleaseService(client: try makeClient())
            let versionID = try await service.updateWhatsNew(
                bundleID: args.require("bundle_id"),
                locale: args.require("locale"),
                whatsNew: args.require("text")
            )
            return try json(WhatsNewResult(appStoreVersionID: versionID, locale: try args.require("locale")))
        },

        ToolSpec(
            name: "asc_update_version_localization",
            description: """
                Update description, keywords, and/or promotional text for one locale on \
                the app's latest App Store version. Pass only the fields to change — \
                omitted fields are left untouched. THIS CHANGES PUBLIC-FACING STORE \
                METADATA. Description and keywords are locked once a version is in \
                review; promotional text can still be changed on a READY_FOR_SALE \
                version without a new build or review.
                """,
            arguments: [
                .string("bundle_id", "The app's bundle identifier.", required: true),
                .string("locale", "Locale to update, e.g. en-US.", required: true),
                .string("description", "New description text (optional)."),
                .string("keywords", "New comma-separated keywords, max 100 characters (optional)."),
                .string("promotional_text", "New promotional text, max 170 characters (optional)."),
            ],
            isReadOnly: false
        ) { args, makeClient in
            let service = AppStoreReleaseService(client: try makeClient())
            let versionID = try await service.updateVersionLocalization(
                bundleID: args.require("bundle_id"),
                locale: args.require("locale"),
                description: args.string("description"),
                keywords: args.string("keywords"),
                promotionalText: args.string("promotional_text")
            )
            return try json(VersionLocalizationResult(appStoreVersionID: versionID, locale: try args.require("locale")))
        },

        ToolSpec(
            name: "asc_update_app_info_localization",
            description: """
                Update the app name and/or subtitle for one locale at the app-info \
                level. Pass only the fields to change — omitted fields are left \
                untouched. THIS CHANGES PUBLIC-FACING STORE METADATA. Unlike \
                asc_update_version_localization, this is app-wide rather than \
                version-scoped: it is not blocked while a version is in review.
                """,
            arguments: [
                .string("bundle_id", "The app's bundle identifier.", required: true),
                .string("locale", "Locale to update, e.g. en-US.", required: true),
                .string("name", "New app name, max 30 characters (optional)."),
                .string("subtitle", "New subtitle, max 30 characters (optional)."),
            ],
            isReadOnly: false
        ) { args, makeClient in
            let service = AppStoreReleaseService(client: try makeClient())
            let appInfoID = try await service.updateAppInfoLocalization(
                bundleID: args.require("bundle_id"),
                locale: args.require("locale"),
                name: args.string("name"),
                subtitle: args.string("subtitle")
            )
            return try json(AppInfoLocalizationResult(appInfoID: appInfoID, locale: try args.require("locale")))
        },

        ToolSpec(
            name: "asc_submit_for_review",
            description: """
                Submit the app's latest App Store version to App Review: sets the release \
                type, optionally creates a phased release, and creates the review submission. \
                'version_string' is used only if a new version record has to be created. \
                THIS SUBMITS THE APP TO APPLE FOR REVIEW — an irreversible, public action. \
                Check asc_submission_status first, and confirm with the user before calling.
                """,
            arguments: [
                .string("bundle_id", "The app's bundle identifier.", required: true),
                .string("version_string", "Version to create if no editable version exists, e.g. 1.4.0."),
                .boolean("automatic_release", "Release automatically once approved."),
                .boolean("phased_release", "Roll the release out over Apple's 7-day schedule."),
            ],
            isReadOnly: false
        ) { args, makeClient in
            let service = AppStoreReleaseService(client: try makeClient())
            let result = try await service.submitForReview(
                bundleID: args.require("bundle_id"),
                automaticRelease: args.bool("automatic_release"),
                phasedRelease: args.bool("phased_release"),
                resolveVersionString: {
                    guard let version = args.string("version_string") else {
                        throw ASCError.invalidConfiguration(
                            reason: """
                                No editable App Store version exists and no 'version_string' was given, \
                                so there is nothing to submit. Pass the version to create, e.g. 1.4.0.
                                """
                        )
                    }
                    return version
                }
            )
            return try json(
                SubmissionResult(
                    appStoreVersionID: result.appStoreVersionID,
                    reviewSubmissionID: result.reviewSubmissionID
                ))
        },

        ToolSpec(
            name: "asc_respond_to_review",
            description: """
                Publish a developer reply to an App Store customer review, replacing any \
                reply already posted (a review holds at most one). Get review ids from \
                asc_list_customer_reviews. Apple screens the text first, so the reply starts \
                as PENDING_PUBLISH. THIS POSTS A PUBLIC REPLY ON THE APP STORE — confirm the \
                exact text with the user before calling.
                """,
            arguments: [
                .string("review_id", "The customer review id.", required: true),
                .string("text", "The reply text.", required: true),
            ],
            isReadOnly: false
        ) { args, makeClient in
            try json(
                await makeClient().respondToCustomerReview(
                    reviewID: args.require("review_id"),
                    responseBody: args.require("text")
                ))
        },

        ToolSpec(
            name: "asc_add_build_to_beta_group",
            description: """
                Make a build available to a TestFlight beta group. Internal groups can \
                install it once processing finishes; external groups also need beta app \
                review (check asc_testflight_build_status). Get group ids from \
                asc_list_beta_groups and build ids from asc_list_builds. THIS GIVES THE \
                GROUP'S TESTERS ACCESS TO THE BUILD.
                """,
            arguments: [
                .string("beta_group_id", "The beta group id.", required: true),
                .string("build_id", "The build id.", required: true),
            ],
            isReadOnly: false
        ) { args, makeClient in
            let groupID = try args.require("beta_group_id")
            let buildID = try args.require("build_id")
            try await makeClient().addBuilds([buildID], toBetaGroup: groupID)
            return try json(BuildGroupResult(betaGroupID: groupID, buildID: buildID))
        },

        ToolSpec(
            name: "asc_invite_beta_tester",
            description: """
                Add a person to a TestFlight beta group by email. THIS SENDS THEM A \
                TESTFLIGHT INVITATION EMAIL — confirm the address with the user before \
                calling. A 409 usually means they are already a tester in that group. Get \
                group ids from asc_list_beta_groups.
                """,
            arguments: [
                .string("email", "The tester's email address.", required: true),
                .string("beta_group_id", "The beta group to add them to.", required: true),
                .string("first_name", "First name (optional)."),
                .string("last_name", "Last name (optional)."),
            ],
            isReadOnly: false
        ) { args, makeClient in
            try json(
                await makeClient().inviteBetaTester(
                    email: args.require("email"),
                    firstName: args.string("first_name"),
                    lastName: args.string("last_name"),
                    betaGroupIDs: [args.require("beta_group_id")]
                ))
        },

        ToolSpec(
            name: "asc_create_analytics_report_request",
            description: """
                Create an App Store analytics report request for an app, which is what makes \
                reports exist at all — asc_get_analytics_report returns nothing until one is \
                in place. ONGOING (default) produces data daily from now on; \
                ONE_TIME_SNAPSHOT backfills once. Apple starts producing data the following \
                day, so reports stay empty for a while after this. Pass either app_id or \
                bundle_id.
                """,
            arguments: [
                .string("app_id", "App Store Connect app id (or pass bundle_id)."),
                .string("bundle_id", "Bundle identifier, resolved to an app id."),
                .string("access_type", "ONGOING (default) or ONE_TIME_SNAPSHOT."),
            ],
            isReadOnly: false
        ) { args, makeClient in
            let client = try makeClient()
            let appID = try await AppStoreTools.resolveAppID(args, client: client)
            return try json(
                await client.createAnalyticsReportRequest(
                    appID: appID,
                    accessType: args.string("access_type") ?? "ONGOING"
                ))
        },
    ]

    /// Write tools keyed by name, so the dispatcher can tell "disabled" from "unknown".
    static let specsByName: [String: ToolSpec] = Dictionary(uniqueKeysWithValues: specs.map { ($0.name, $0) })

    // MARK: - Payloads

    private struct WhatsNewResult: Encodable {
        let appStoreVersionID: String
        let locale: String
    }

    private struct VersionLocalizationResult: Encodable {
        let appStoreVersionID: String
        let locale: String
    }

    private struct AppInfoLocalizationResult: Encodable {
        let appInfoID: String
        let locale: String
    }

    private struct BuildGroupResult: Encodable {
        let betaGroupID: String
        let buildID: String
    }

    private struct SubmissionResult: Encodable {
        let appStoreVersionID: String
        let reviewSubmissionID: String
    }

    private static func json<T: Encodable>(_ value: T) throws -> CallTool.Result {
        try CITools.json(value)
    }
}
