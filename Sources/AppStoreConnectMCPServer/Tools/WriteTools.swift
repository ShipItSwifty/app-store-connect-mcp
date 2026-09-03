import AppStoreConnectKit
import Foundation
import MCP

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

    private struct SubmissionResult: Encodable {
        let appStoreVersionID: String
        let reviewSubmissionID: String
    }

    private static func json<T: Encodable>(_ value: T) throws -> CallTool.Result {
        try CITools.json(value)
    }
}
