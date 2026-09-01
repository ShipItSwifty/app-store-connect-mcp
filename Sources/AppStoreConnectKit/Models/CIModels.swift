import Foundation

// MARK: - Xcode Cloud (App Store Connect CI) resources
//
// These map the `ci*` resource family of the App Store Connect API, which is how
// Xcode Cloud exposes products, workflows, build runs, per-action results, issues,
// test results, and artifacts.

/// An Xcode Cloud product — the CI configuration attached to one app.
public struct CIProduct: Codable, Sendable {
    public let id: String
    public let attributes: Attributes?

    public init(id: String, attributes: Attributes? = nil) {
        self.id = id
        self.attributes = attributes
    }

    public struct Attributes: Codable, Sendable {
        public let name: String?
        public let productType: String?
        public let createdDate: String?

        public init(name: String? = nil, productType: String? = nil, createdDate: String? = nil) {
            self.name = name
            self.productType = productType
            self.createdDate = createdDate
        }
    }
}

/// An Xcode Cloud workflow (e.g. "Build", "Release").
public struct CIWorkflow: Codable, Sendable {
    public let id: String
    public let attributes: Attributes?

    public init(id: String, attributes: Attributes? = nil) {
        self.id = id
        self.attributes = attributes
    }

    public struct Attributes: Codable, Sendable {
        public let name: String?
        public let description: String?
        public let isEnabled: Bool?
        public let isLockedForEditing: Bool?
        public let lastModifiedDate: String?
        /// The ordered build/analyze/test/archive steps the workflow runs. Present
        /// on the single-workflow endpoint; carries each test action's test-plan config.
        public let actions: [Action]?

        public init(
            name: String? = nil,
            description: String? = nil,
            isEnabled: Bool? = nil,
            isLockedForEditing: Bool? = nil,
            lastModifiedDate: String? = nil,
            actions: [Action]? = nil
        ) {
            self.name = name
            self.description = description
            self.isEnabled = isEnabled
            self.isLockedForEditing = isLockedForEditing
            self.lastModifiedDate = lastModifiedDate
            self.actions = actions
        }
    }

    /// One step in a workflow's action list.
    public struct Action: Codable, Sendable {
        public let name: String?
        /// `BUILD`, `ANALYZE`, `TEST`, `ARCHIVE`.
        public let actionType: String?
        public let scheme: String?
        public let platform: String?
        /// For `TEST` actions: which test plans run and how they were selected.
        public let testConfiguration: TestConfiguration?

        public init(
            name: String? = nil,
            actionType: String? = nil,
            scheme: String? = nil,
            platform: String? = nil,
            testConfiguration: TestConfiguration? = nil
        ) {
            self.name = name
            self.actionType = actionType
            self.scheme = scheme
            self.platform = platform
            self.testConfiguration = testConfiguration
        }

        /// A `TEST` action's test-plan selection.
        public struct TestConfiguration: Codable, Sendable {
            /// `USE_SCHEME_SETTINGS`, `SPECIFIC_TEST_PLANS`, `USE_TEST_PLAN`, …
            public let kind: String?
            /// The selected test plans (populated when `kind == SPECIFIC_TEST_PLANS`).
            public let testPlans: [TestPlan]?

            public init(kind: String? = nil, testPlans: [TestPlan]? = nil) {
                self.kind = kind
                self.testPlans = testPlans
            }

            public struct TestPlan: Codable, Sendable {
                /// The test plan's name, e.g. `Smoke.xctestplan` → `"Smoke"`.
                public let name: String?

                public init(name: String? = nil) {
                    self.name = name
                }
            }
        }
    }
}

/// A single execution of an Xcode Cloud workflow.
public struct CIBuildRun: Codable, Sendable {
    public let id: String
    public let attributes: Attributes?

    public init(id: String, attributes: Attributes? = nil) {
        self.id = id
        self.attributes = attributes
    }

    public struct Attributes: Codable, Sendable {
        /// Monotonically increasing build number for the workflow.
        public let number: Int?
        /// `RUNNING`, `COMPLETE`, `PENDING`, etc.
        public let executionProgress: String?
        /// `SUCCEEDED`, `FAILED`, `ERRORED`, `CANCELED`, `SKIPPED`, `INVALID`.
        public let completionStatus: String?
        public let startReason: String?
        public let createdDate: String?
        public let startedDate: String?
        public let finishedDate: String?
        public let sourceCommit: SourceCommit?
        public let destinationCommit: SourceCommit?
        public let isPullRequestBuild: Bool?

        public init(
            number: Int? = nil,
            executionProgress: String? = nil,
            completionStatus: String? = nil,
            startReason: String? = nil,
            createdDate: String? = nil,
            startedDate: String? = nil,
            finishedDate: String? = nil,
            sourceCommit: SourceCommit? = nil,
            destinationCommit: SourceCommit? = nil,
            isPullRequestBuild: Bool? = nil
        ) {
            self.number = number
            self.executionProgress = executionProgress
            self.completionStatus = completionStatus
            self.startReason = startReason
            self.createdDate = createdDate
            self.startedDate = startedDate
            self.finishedDate = finishedDate
            self.sourceCommit = sourceCommit
            self.destinationCommit = destinationCommit
            self.isPullRequestBuild = isPullRequestBuild
        }

        public struct SourceCommit: Codable, Sendable {
            public let commitSha: String?
            public let message: String?
            public let webUrl: String?

            public init(commitSha: String? = nil, message: String? = nil, webUrl: String? = nil) {
                self.commitSha = commitSha
                self.message = message
                self.webUrl = webUrl
            }
        }
    }

    /// Wall-clock seconds between `startedDate` and `finishedDate`, or `nil` if the
    /// run has not finished or the dates are unparseable. A large value here is the
    /// quickest tell for a timed-out build.
    public var durationSeconds: Double? {
        CIDate.durationSeconds(from: attributes?.startedDate, to: attributes?.finishedDate)
    }

    /// Statuses that indicate a build run genuinely failed (as opposed to
    /// succeeding, being skipped, or still running). Used to filter run lists.
    ///
    /// Deliberately excludes `CANCELED`: a run someone stopped by hand is not a red
    /// build. Action-level collection uses the wider
    /// ``CIBuildAction/unsuccessfulCompletionStatuses`` instead — see the note there.
    public static let failureCompletionStatuses: Set<String> = ["FAILED", "ERRORED", "INVALID"]

    /// Whether this run's `completionStatus` counts as a failure.
    public var isFailure: Bool {
        Self.failureCompletionStatuses.contains((attributes?.completionStatus ?? "").uppercased())
    }
}

/// One action (a build/analyze/test/archive step) inside a build run.
public struct CIBuildAction: Codable, Sendable {
    public let id: String
    public let attributes: Attributes?

    public init(id: String, attributes: Attributes? = nil) {
        self.id = id
        self.attributes = attributes
    }

    public struct Attributes: Codable, Sendable {
        public let name: String?
        /// `BUILD`, `ANALYZE`, `TEST`, `ARCHIVE`.
        public let actionType: String?
        public let executionProgress: String?
        public let completionStatus: String?
        public let startedDate: String?
        public let finishedDate: String?
        public let issueCounts: IssueCounts?

        public init(
            name: String? = nil,
            actionType: String? = nil,
            executionProgress: String? = nil,
            completionStatus: String? = nil,
            startedDate: String? = nil,
            finishedDate: String? = nil,
            issueCounts: IssueCounts? = nil
        ) {
            self.name = name
            self.actionType = actionType
            self.executionProgress = executionProgress
            self.completionStatus = completionStatus
            self.startedDate = startedDate
            self.finishedDate = finishedDate
            self.issueCounts = issueCounts
        }

        public struct IssueCounts: Codable, Sendable {
            public let analyzerWarnings: Int?
            public let errors: Int?
            public let testFailures: Int?
            public let warnings: Int?

            public init(
                analyzerWarnings: Int? = nil,
                errors: Int? = nil,
                testFailures: Int? = nil,
                warnings: Int? = nil
            ) {
                self.analyzerWarnings = analyzerWarnings
                self.errors = errors
                self.testFailures = testFailures
                self.warnings = warnings
            }
        }
    }

    /// Wall-clock seconds this action ran, or `nil` if it has not finished or the
    /// dates are unparseable.
    public var durationSeconds: Double? {
        CIDate.durationSeconds(from: attributes?.startedDate, to: attributes?.finishedDate)
    }

    /// Action statuses worth gathering diagnostics for.
    ///
    /// Wider than ``CIBuildRun/failureCompletionStatuses`` by `CANCELED` on purpose:
    /// when a run fails, Xcode Cloud cancels its remaining actions, and those
    /// canceled actions still carry issues that explain the break.
    public static let unsuccessfulCompletionStatuses: Set<String> = [
        "FAILED", "ERRORED", "INVALID", "CANCELED",
    ]

    /// Whether this action ended in a state worth collecting diagnostics for.
    public var isUnsuccessful: Bool {
        Self.unsuccessfulCompletionStatuses.contains((attributes?.completionStatus ?? "").uppercased())
    }
}

/// A single issue (error / warning / analyzer finding) emitted by a build action.
public struct CIIssue: Codable, Sendable {
    public let id: String
    public let attributes: Attributes?

    public init(id: String, attributes: Attributes? = nil) {
        self.id = id
        self.attributes = attributes
    }

    public struct Attributes: Codable, Sendable {
        /// `ANALYZER_WARNING`, `ERROR`, `SCAN_WARNING`, `TEST_FAILURE`, `WARNING`.
        public let issueType: String?
        public let message: String?
        public let fileSource: FileSource?
        public let category: String?

        public init(
            issueType: String? = nil,
            message: String? = nil,
            fileSource: FileSource? = nil,
            category: String? = nil
        ) {
            self.issueType = issueType
            self.message = message
            self.fileSource = fileSource
            self.category = category
        }

        public struct FileSource: Codable, Sendable {
            public let path: String?
            public let lineNumber: Int?

            public init(path: String? = nil, lineNumber: Int? = nil) {
                self.path = path
                self.lineNumber = lineNumber
            }
        }
    }
}

/// A test result (one test class or destination outcome) for a build action.
public struct CITestResult: Codable, Sendable {
    public let id: String
    public let attributes: Attributes?

    public init(id: String, attributes: Attributes? = nil) {
        self.id = id
        self.attributes = attributes
    }

    public struct Attributes: Codable, Sendable {
        public let className: String?
        public let name: String?
        /// `SUCCESS`, `FAILURE`, `MIXED`, `SKIPPED`, `EXPECTED_FAILURE`.
        public let status: String?
        public let message: String?
        public let fileSource: CIIssue.Attributes.FileSource?
        public let destinationTestResults: [DestinationTestResult]?

        public init(
            className: String? = nil,
            name: String? = nil,
            status: String? = nil,
            message: String? = nil,
            fileSource: CIIssue.Attributes.FileSource? = nil,
            destinationTestResults: [DestinationTestResult]? = nil
        ) {
            self.className = className
            self.name = name
            self.status = status
            self.message = message
            self.fileSource = fileSource
            self.destinationTestResults = destinationTestResults
        }

        public struct DestinationTestResult: Codable, Sendable {
            public let deviceName: String?
            public let osVersion: String?
            public let status: String?
            public let duration: Double?

            public init(
                deviceName: String? = nil,
                osVersion: String? = nil,
                status: String? = nil,
                duration: Double? = nil
            ) {
                self.deviceName = deviceName
                self.osVersion = osVersion
                self.status = status
                self.duration = duration
            }
        }
    }
}

/// A downloadable artifact (log bundle, xcresult, product) for a build action.
public struct CIArtifact: Codable, Sendable {
    public let id: String
    public let attributes: Attributes?

    public init(id: String, attributes: Attributes? = nil) {
        self.id = id
        self.attributes = attributes
    }

    public struct Attributes: Codable, Sendable {
        public let fileType: String?
        public let fileName: String?
        public let fileSize: Int?
        /// Short-lived signed URL for downloading the artifact.
        public let downloadUrl: String?

        public init(
            fileType: String? = nil,
            fileName: String? = nil,
            fileSize: Int? = nil,
            downloadUrl: String? = nil
        ) {
            self.fileType = fileType
            self.fileName = fileName
            self.fileSize = fileSize
            self.downloadUrl = downloadUrl
        }
    }
}
