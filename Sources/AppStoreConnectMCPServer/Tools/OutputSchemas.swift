import MCP

/// JSON Schemas for the tools whose result is a stable, documented object.
///
/// A tool that declares one of these advertises it as `outputSchema`, and its result
/// carries the same JSON as `structuredContent` beside the text block, so a host can
/// validate and address fields instead of parsing prose. Only the aggregating reports
/// get one: they are what an agent reasons over, and their shapes are this package's
/// own models rather than Apple's pass-through envelopes.
///
/// Every property listed as `required` is a non-optional stored property of the model
/// it describes; optionals are omitted from the JSON when `nil`, so they are never
/// required. `StructuredOutputTests` validates real tool output against each schema.
enum OutputSchemas {
    // MARK: - Building blocks

    static let string: Value = ["type": "string"]
    static let integer: Value = ["type": "integer"]
    static let number: Value = ["type": "number"]
    static let boolean: Value = ["type": "boolean"]

    static func array(of items: Value) -> Value {
        ["type": "array", "items": items]
    }

    static func object(_ properties: [String: Value], required: [String] = []) -> Value {
        var schema: [String: Value] = ["type": "object", "properties": .object(properties)]
        if !required.isEmpty {
            schema["required"] = .array(required.map { .string($0) })
        }
        return .object(schema)
    }

    // MARK: - Xcode Cloud

    /// `CIFailureReport`.
    static let failureReport: Value = object(
        [
            "buildRunID": string,
            "workflowName": string,
            "number": integer,
            "completionStatus": string,
            "sourceCommitSha": string,
            "sourceCommitMessage": string,
            "startedDate": string,
            "finishedDate": string,
            "durationSeconds": number,
            "failedActions": array(of: failedAction),
        ],
        required: ["buildRunID", "failedActions"]
    )

    /// `CIFailureReport.FailedAction`.
    static let failedAction: Value = object(
        [
            "id": string,
            "name": string,
            "actionType": string,
            "completionStatus": string,
            "startedDate": string,
            "finishedDate": string,
            "durationSeconds": number,
            "issues": array(
                of: object(["type": string, "message": string, "path": string, "line": integer])
            ),
            "failedTests": array(
                of: object(["className": string, "name": string, "status": string, "message": string])
            ),
            "artifacts": array(
                of: object(["fileType": string, "fileName": string, "downloadUrl": string])
            ),
        ],
        required: ["id", "issues", "failedTests", "artifacts"]
    )

    /// `CIFailureReportWithLogs`.
    static let failureReportWithLogs: Value = object(
        [
            "report": failureReport,
            "logFindingsByAction": ["type": "object"],
            "skippedArtifacts": array(of: string),
        ],
        required: ["report", "logFindingsByAction", "skippedArtifacts"]
    )

    /// `CILatestFailure`.
    static let latestFailure: Value = object(
        [
            "found": boolean,
            "workflowsScanned": integer,
            "workflowID": string,
            "workflowName": string,
            "buildRunID": string,
            "report": failureReport,
        ],
        required: ["found", "workflowsScanned"]
    )

    // MARK: - App Store

    /// `AppStoreSubmissionService.SubmissionStatusReport`. Nested records are typed
    /// but not enumerated: their fields mirror Apple's attributes and grow with them.
    static let submissionStatus: Value = object(
        [
            "appID": string,
            "bundleID": string,
            "latestVersion": ["type": "object"],
            "reviewSubmission": ["type": "object"],
            "items": array(of: ["type": "object"]),
            "needsDeveloperAction": boolean,
            "diagnosis": string,
            "buildAttached": boolean,
            "attachedBuild": ["type": "object"],
            "candidateBuild": ["type": "object"],
        ],
        required: ["appID", "bundleID", "items", "needsDeveloperAction", "diagnosis"]
    )

    /// `asc_rate_limit_status`: `{known, status?}` around a `RateLimitStatus`.
    static let rateLimitReport: Value = object(
        [
            "known": boolean,
            "status": object(
                [
                    "limit": integer,
                    "remaining": integer,
                    "usedFraction": number,
                    "throttleThreshold": number,
                ],
                required: ["limit", "remaining", "usedFraction", "throttleThreshold"]
            ),
        ],
        required: ["known"]
    )
}
