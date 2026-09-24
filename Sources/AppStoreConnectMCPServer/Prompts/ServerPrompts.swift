import Foundation
import MCP

/// Guidance sent to the host in the `initialize` result's `instructions` field.
///
/// Hosts that honour it (Claude Code, Claude Desktop, …) put it in the model's context
/// before any tool is called, so it is where the catalog-wide facts belong: where to
/// start, which tool collapses a walk into one call, and what the rate limit costs.
/// Per-tool detail stays in each tool's description.
enum ServerInstructions {
    static let text = """
        App Store Connect read API: Xcode Cloud builds, App Store versions and review, \
        TestFlight, production diagnostics, reports.

        Start points:
        - No ids yet: asc_list_apps (by bundle_id or name) gives the app id. Every \
        app-scoped tool also accepts bundle_id directly at the cost of one lookup.
        - "What broke in CI?": asc_ci_latest_failure with app_id, then \
        asc_ci_failure_report_with_logs on the returned build_run_id for parsed log findings. \
        Do not walk products -> workflows -> runs -> actions by hand unless these miss.
        - "Why is my version stuck/rejected?": asc_submission_status.
        - "Why can't testers see the build?": asc_testflight_build_status.
        - "What is crashing or hanging?": asc_list_beta_feedback (kind crash) for TestFlight \
        crash logs; asc_list_diagnostic_signatures then asc_get_diagnostic_logs for hangs, \
        slow launches, and disk writes.
        - Anything without a typed tool: asc_api_get with a /v1/ path.

        Budget: Apple enforces an hourly request limit per key, and the aggregating tools \
        make several requests each. A warning block is appended when usage nears the throttle; \
        check asc_rate_limit_status before broad scans.

        Every advertised tool is read-only unless ASC_ENABLE_WRITES is set. Prompts on this \
        server (triage_ci_failure, diagnose_review, testflight_availability, \
        investigate_crashes, release_health) script the common investigations.
        """
}

/// One MCP prompt: its advertised shape and the text it expands to.
///
/// Like ``ToolSpec``, the advertisement and the implementation are one value, so the
/// list the host sees and what `prompts/get` serves cannot drift apart.
struct PromptSpec: Sendable {
    let name: String
    let title: String
    let description: String
    let arguments: [Prompt.Argument]
    let render: @Sendable ([String: String]) -> String

    var prompt: Prompt {
        Prompt(name: name, title: title, description: description, arguments: arguments)
    }
}

/// Investigation playbooks exposed as MCP prompts.
///
/// A prompt is the portable form of a skill: a host lists them (Claude Code shows each
/// as a `/mcp__<server>__<name>` command) and expanding one hands the model a worked
/// plan naming the tools to call in order. They only reference read-only tools, so
/// running one never needs `ASC_ENABLE_WRITES`.
enum ServerPrompts {
    static let specs: [PromptSpec] = [
        PromptSpec(
            name: "triage_ci_failure",
            title: "Triage an Xcode Cloud failure",
            description: "Find the most recent failed Xcode Cloud build and explain the root cause with file/line evidence.",
            arguments: [
                .init(name: "bundle_id", description: "Bundle identifier of the app (or pass app_id)."),
                .init(name: "app_id", description: "App Store Connect app id."),
                .init(name: "build_run_id", description: "A specific build run to explain instead of the latest failure."),
            ]
        ) { args in
            let start: String
            if let run = args["build_run_id"] {
                start = "1. Call asc_ci_failure_report_with_logs with build_run_id \"\(run)\"."
            } else if let appID = args["app_id"] {
                start = """
                    1. Call asc_ci_latest_failure with app_id "\(appID)". If it returns found=false, say so and stop.
                    2. Call asc_ci_failure_report_with_logs with the returned build_run_id.
                    """
            } else {
                start = """
                    1. Resolve the app: call asc_list_apps\(scope(args, "bundle_id", as: "bundle_id")) and take its id.
                    2. Call asc_ci_latest_failure with that app_id. If it returns found=false, say so and stop.
                    3. Call asc_ci_failure_report_with_logs with the returned build_run_id.
                    """
            }
            return """
                Investigate why an Xcode Cloud build failed.

                \(start)

                Then reason over the report:
                - Compiler/linker errors: quote the first error per file with file:line; later errors are often cascades.
                - Failed tests: group by test class; separate assertion failures from crashes and timeouts.
                - A run or action whose durationSeconds is near 7200 hit Xcode Cloud's 120-minute limit — call it a timeout.
                - Code-signing errors: check asc_signing_assets for expired or invalid certificates and profiles.
                - Tests that never ran or ran the wrong plan: check asc_ci_list_test_plans for the workflow.
                - Artifacts listed under skippedArtifacts (xcresult) are not parsed here; mention them if the logs are inconclusive.

                Answer with: root cause (one sentence), evidence (file:line or log excerpt), suggested fix, \
                and your confidence. Do not re-fetch data the report already contains.
                """
        },

        PromptSpec(
            name: "diagnose_review",
            title: "Diagnose App Review status",
            description: "Explain where the latest App Store version stands in review and what the developer must do next.",
            arguments: [
                .init(name: "bundle_id", description: "Bundle identifier of the app.", required: true)
            ]
        ) { args in
            """
            Diagnose the App Store review status of \(quoted(args, "bundle_id")).

            1. Call asc_submission_status with bundle_id \(quoted(args, "bundle_id")).
            2. If the version or an item was rejected (REJECTED, METADATA_REJECTED, INVALID_BINARY) or developer action is required:
               - asc_list_app_infos — the app-level listing is reviewed separately and can be METADATA_REJECTED on its own.
               - asc_review_details — contact, demo-account requirement, and reviewer notes App Review was given.
               - asc_get_version_metadata with the version id — the listing text that was reviewed.
            3. If the state is PREPARE_FOR_SUBMISSION or no build is attached, call asc_list_builds for the app and check \
            processingState, buildAudienceType (INTERNAL_ONLY can never ship), and usesNonExemptEncryption (null blocks submission).

            Answer with: current state in plain language, why it is there, and the concrete next step. \
            Apple's rejection message text is only visible in App Store Connect's Resolution Center; say so if it is needed.
            """
        },

        PromptSpec(
            name: "testflight_availability",
            title: "Why can't testers see a build?",
            description: "Explain why a TestFlight build is or isn't available to internal and external testers.",
            arguments: [
                .init(name: "bundle_id", description: "Bundle identifier of the app.", required: true),
                .init(name: "version", description: "Build number (CFBundleVersion). Defaults to the newest build."),
            ]
        ) { args in
            let build = args["version"].map { "build \"\($0)\"" } ?? "the newest build"
            return """
                Explain why \(build) of \(quoted(args, "bundle_id")) is or isn't available to TestFlight testers.

                1. Call asc_testflight_build_status with bundle_id \(quoted(args, "bundle_id"))\
                \(args["version"].map { " and version \"\($0)\"" } ?? "").
                2. If processingState is not VALID, or usesNonExemptEncryption is null, that is the blocker — stop there.
                3. Call asc_list_beta_groups to see which groups exist, whether they auto-add builds, and their public links.
                4. Only if one group looks wrong, call asc_list_beta_testers for it.

                Answer separately for internal and external testers: available or not, the blocking state, and the next step.
                """
        },

        PromptSpec(
            name: "investigate_crashes",
            title: "Investigate crashes and hangs",
            description: "Explain TestFlight crashes and the hang, launch, and disk-write signatures real devices reported.",
            arguments: [
                .init(name: "bundle_id", description: "Bundle identifier of the app.", required: true),
                .init(name: "build_id", description: "Build to inspect. Defaults to the app's newest build."),
            ]
        ) { args in
            let target = args["build_id"].map { "build_id \"\($0)\"" } ?? "bundle_id \(quoted(args, "bundle_id"))"
            return """
                Investigate crashes and hangs of \(quoted(args, "bundle_id")).

                1. Crashes: call asc_list_beta_feedback with kind crash, then asc_get_beta_crash_log for the \
                most recent or most repeated submissions. Crash logs from App Store users are not in the API \
                (Xcode Organizer only); say so if the user needs them.
                2. Hangs, slow launches, excessive disk writes: call asc_list_diagnostic_signatures with \(target). \
                For the two or three heaviest signatures (by weight, or flagged by a regression insight), call \
                asc_get_diagnostic_logs and read the blamed frames; symbolicated app frames with file:line are the lead.
                3. Optionally call asc_perf_power_metrics for launch/hang/memory regressions around the same release.

                Answer with a ranked list: problem, how often it occurs, the app frame to look at, and a likely cause. \
                Say when stacks are unsymbolicated rather than guessing.
                """
        },

        PromptSpec(
            name: "release_health",
            title: "Release health check",
            description: "One-pass status of an app's current release: version state, build, rollout, signing, and recent reviews.",
            arguments: [
                .init(name: "bundle_id", description: "Bundle identifier of the app.", required: true)
            ]
        ) { args in
            """
            Give a release health summary for \(quoted(args, "bundle_id")).

            Call, in this order, and stop drilling into any area that is healthy:
            1. asc_list_app_store_versions (limit 3) — the version in flight and the one on sale.
            2. asc_submission_status — only if the newest version is not READY_FOR_DISTRIBUTION.
            3. asc_phased_release_status — rollout day and share of users, if a phased release is configured.
            4. asc_list_builds (limit 5) — processing failures or missing export-compliance answers.
            5. asc_signing_assets — anything expired or expiring within 30 days.
            6. asc_list_customer_reviews (limit 20) — recurring complaints in recent reviews, especially low ratings.

            Answer with a short table (area, status, action needed) followed by the one thing to do first.
            """
        },
    ]

    /// The prompts advertised to the host.
    static let all: [Prompt] = specs.map(\.prompt)

    private static let specsByName: [String: PromptSpec] = Dictionary(
        uniqueKeysWithValues: specs.map { ($0.name, $0) }
    )

    /// Expands a prompt for `prompts/get`.
    ///
    /// - Throws: `MCPError.invalidParams` for an unknown prompt or a missing required
    ///   argument, so the host can show the user what to fill in.
    static func get(name: String, arguments: [String: String]) throws -> GetPrompt.Result {
        guard let spec = specsByName[name] else {
            throw MCPError.invalidParams("Unknown prompt: \(name)")
        }
        // Hosts send blank form fields as empty strings; treat them as absent.
        let arguments = arguments.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        for argument in spec.arguments where argument.required == true && arguments[argument.name] == nil {
            throw MCPError.invalidParams("Prompt '\(name)' needs the '\(argument.name)' argument.")
        }
        return GetPrompt.Result(
            description: spec.description,
            messages: [.user(.text(text: spec.render(arguments)))]
        )
    }

    // MARK: - Rendering helpers

    private static func quoted(_ args: [String: String], _ key: String) -> String {
        args[key].map { "\"\($0)\"" } ?? "the app"
    }

    /// `" with bundle_id \"…\""` when the argument is present, otherwise a hint to ask.
    private static func scope(_ args: [String: String], _ key: String, as label: String) -> String {
        args[key].map { " with \(label) \"\($0)\"" } ?? " (ask the user which app if it is ambiguous)"
    }
}
