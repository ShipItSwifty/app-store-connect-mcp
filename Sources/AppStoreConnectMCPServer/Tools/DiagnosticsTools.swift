import AppStoreConnectKit
import Foundation
import MCP

/// Tools for what real devices report, as opposed to what CI reports: crash, hang and
/// disk-write signatures with their call stacks, TestFlight crash logs, and the Xcode
/// Organizer power-and-performance metrics.
///
/// Every payload here is normalized before it leaves the server — the raw Apple
/// responses (a call-stack tree per thread per report; every percentile of every
/// metric of every version) are orders of magnitude larger than what a reader acts
/// on, and handing them over verbatim would crowd out the answer.
///
/// Part of the single catalog; see ``CITools/specs``.
enum DiagnosticsTools {
    static let specs: [ToolSpec] = [
        ToolSpec(
            name: "asc_list_diagnostic_signatures",
            description: """
                List the crash, hang, and excessive-disk-write signatures real devices \
                reported against a build — the data behind Xcode's Organizer. Each signature \
                is one class of problem rolled up across every device that hit it, with a \
                'weight' (how many reports) and an insight saying whether it is worse than \
                previous versions. Pass a build_id, or an app_id/bundle_id to use that app's \
                newest build. Feed a signature id to asc_get_diagnostic_logs for the stacks.
                """,
            arguments: [
                .string("build_id", "Build id (from asc_list_builds). Omit to use the app's newest build."),
                .string("app_id", "App Store Connect app id — resolves to its newest build."),
                .string("bundle_id", "Bundle identifier — resolves to its newest build."),
                .string("diagnostic_type", "Filter: DISK_WRITES, HANGS, or LAUNCHES."),
                .integer("limit", "Max signatures to return (default 50)."),
            ]
        ) { args, makeClient in
            let client = try makeClient()
            let buildID = try await resolveBuildID(args, client: client)
            return try json(
                await client.diagnosticSignatures(
                    buildID: buildID,
                    diagnosticType: args.string("diagnostic_type"),
                    limit: args.int("limit", default: 50)
                ))
        },

        ToolSpec(
            name: "asc_get_diagnostic_logs",
            description: """
                Fetch the call stacks behind one diagnostic signature, reduced to the frames \
                Apple blames: symbol name, binary, and file/line where the frames are \
                symbolicated, ranked by sample count, with the app version, OS version and \
                device of each report. This is the closest the API gets to a stack trace from \
                a real user. 'totalFrames' says how many frames the raw report held, so you \
                can tell how much was elided.
                """,
            arguments: [
                .string("signature_id", "Diagnostic signature id (from asc_list_diagnostic_signatures).", required: true),
                .integer("limit", "Max device reports to fetch (default 10)."),
                .integer("max_frames", "Max frames kept per report (default 25)."),
            ]
        ) { args, makeClient in
            try json(
                await makeClient().diagnosticLogSummary(
                    signatureID: args.require("signature_id"),
                    limit: args.int("limit", default: 10, max: 50),
                    maxFramesPerReport: args.int("max_frames", default: 25, max: 200)
                ))
        },

        ToolSpec(
            name: "asc_get_beta_crash_log",
            description: """
                Download the crash log attached to a TestFlight crash feedback submission \
                (the id comes from asc_list_beta_feedback with kind='crash'). Returns the \
                symbolicated log text. Apple attaches logs asynchronously, so a recent \
                submission may report {"available": false} — that is not an error.
                """,
            arguments: [
                .string("feedback_id", "Beta feedback crash submission id.", required: true)
            ]
        ) { args, makeClient in
            let text = try await makeClient().betaCrashLog(feedbackID: args.require("feedback_id"))
            guard let text else { return try json(BetaCrashLogPayload(available: false, logText: nil)) }
            return try json(BetaCrashLogPayload(available: true, logText: text))
        },

        ToolSpec(
            name: "asc_perf_power_metrics",
            description: """
                Power and performance metrics from real devices: launch time, hang rate, \
                memory, disk writes, battery, animation hitches and terminations. Returns \
                Apple's flagged regressions (with its own summary text and the worst-hit \
                device/percentile) plus the newest measurement of each metric per percentile, \
                with its unit and goal band. Use this to answer "did the last release make \
                the app slower". Pass either app_id or bundle_id.
                """,
            arguments: [
                .string("app_id", "App Store Connect app id (or pass bundle_id)."),
                .string("bundle_id", "Bundle identifier, resolved to an app id."),
                .string("metric_type", "DISK, HANG, BATTERY, LAUNCH, MEMORY, ANIMATION, or TERMINATION."),
                .string("platform", "IOS, MAC_OS, TV_OS, or WATCH_OS."),
                .string("device_type", "Device filter, e.g. all_iPhones."),
                .boolean("raw", "Return Apple's full unreduced payload instead of the summary."),
            ]
        ) { args, makeClient in
            let client = try makeClient()
            let appID = try await AppStoreTools.resolveAppID(args, client: client)
            let platform = args.string("platform")
            let metricType = args.string("metric_type")
            let deviceType = args.string("device_type")
            if args.bool("raw") {
                return try json(
                    await client.perfPowerMetrics(
                        appID: appID, platform: platform, metricType: metricType, deviceType: deviceType))
            }
            return try json(
                await client.perfPowerMetricsSummary(
                    appID: appID, platform: platform, metricType: metricType, deviceType: deviceType))
        },
    ]

    /// `asc_get_beta_crash_log` payload.
    private struct BetaCrashLogPayload: Encodable {
        let available: Bool
        let logText: String?
    }

    /// Resolves `build_id`, or the newest build of `app_id` / `bundle_id`.
    ///
    /// Signatures hang off a build, but a caller investigating "is the app crashing"
    /// starts from the app, and the newest build is what they mean.
    private static func resolveBuildID(_ args: ToolArguments, client: AppStoreConnectClient) async throws -> String {
        if let buildID = args.string("build_id") { return buildID }
        let appID = try await AppStoreTools.resolveAppID(args, client: client)
        let builds = try await client.builds(appID: appID, limit: 1)
        guard let build = builds.data.first else {
            throw ASCError.apiError(statusCode: 404, body: "App '\(appID)' has no uploaded builds.")
        }
        return build.id
    }

    private static func json<T: Encodable>(_ value: T) throws -> CallTool.Result {
        try CITools.json(value)
    }
}
