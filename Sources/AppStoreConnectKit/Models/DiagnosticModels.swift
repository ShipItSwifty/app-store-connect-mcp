import Foundation

// MARK: - Production diagnostics models
//
// The shapes behind `/v1/builds/{id}/diagnosticSignatures`, its logs, and
// `/v1/apps/{id}/perfPowerMetrics` — the metrics and crash/hang signatures Xcode's
// Organizer shows, aggregated from real devices.
//
// Apple's raw payloads here are *large*: a diagnostic log carries a full call-stack
// tree per thread, and a metrics response carries every percentile of every metric
// for every device and version. Both are far too big to hand an agent verbatim, so
// each raw shape has a normalized summary alongside it (``DiagnosticLogSummary``,
// ``PerfPowerMetricsSummary``) that keeps the parts a reader acts on.

/// A `diagnosticSignatures` resource — one class of crash, hang, or excessive
/// disk write, aggregated across the devices that reported it.
public struct ASCDiagnosticSignature: Codable, Sendable {
    /// Unique identifier, used to fetch the signature's logs.
    public let id: String
    /// Signature attributes.
    public let attributes: Attributes?

    /// Creates an `ASCDiagnosticSignature`.
    public init(id: String, attributes: Attributes? = nil) {
        self.id = id
        self.attributes = attributes
    }

    /// Attributes of a diagnostic signature.
    public struct Attributes: Codable, Sendable {
        /// `DISK_WRITES`, `HANGS`, or `LAUNCHES`.
        public let diagnosticType: String?
        /// Apple's opaque signature identifier for this class of report.
        public let signature: String?
        /// How many reports rolled up into this signature — the ranking key.
        public let weight: Double?
        /// Insight into how this signature compares with previous versions.
        public let insight: Insight?

        /// Creates `ASCDiagnosticSignature.Attributes`.
        public init(
            diagnosticType: String? = nil,
            signature: String? = nil,
            weight: Double? = nil,
            insight: Insight? = nil
        ) {
            self.diagnosticType = diagnosticType
            self.signature = signature
            self.weight = weight
            self.insight = insight
        }

        /// How a signature is trending against earlier versions.
        public struct Insight: Codable, Sendable {
            /// `UP` or `DOWN`.
            public let direction: String?
            public let insightType: String?
            public let referenceVersions: [ReferenceVersion]?

            /// Creates an `Insight`.
            public init(
                direction: String? = nil,
                insightType: String? = nil,
                referenceVersions: [ReferenceVersion]? = nil
            ) {
                self.direction = direction
                self.insightType = insightType
                self.referenceVersions = referenceVersions
            }

            /// One earlier version this signature is compared against.
            public struct ReferenceVersion: Codable, Sendable {
                public let version: String?
                public let value: Double?

                /// Creates a `ReferenceVersion`.
                public init(version: String? = nil, value: Double? = nil) {
                    self.version = version
                    self.value = value
                }
            }
        }
    }
}

/// The raw `/v1/diagnosticSignatures/{id}/logs` payload.
///
/// Note this endpoint does *not* use the JSON:API envelope the rest of the API does:
/// it answers with `{"version": …, "productData": [...]}`.
public struct DiagnosticLogsResponse: Codable, Sendable {
    public let version: String?
    public let productData: [ProductData]?

    /// Creates a `DiagnosticLogsResponse`.
    public init(version: String? = nil, productData: [ProductData]? = nil) {
        self.version = version
        self.productData = productData
    }

    /// The logs gathered for one signature.
    public struct ProductData: Codable, Sendable {
        public let signatureId: String?
        public let diagnosticLogs: [Log]?

        /// Creates a `ProductData`.
        public init(signatureId: String? = nil, diagnosticLogs: [Log]? = nil) {
            self.signatureId = signatureId
            self.diagnosticLogs = diagnosticLogs
        }

        /// One device's report: what it was doing and the stacks it was in.
        public struct Log: Codable, Sendable {
            public let diagnosticMetaData: MetaData?
            public let callStackTree: [CallStackTree]?

            /// Creates a `Log`.
            public init(diagnosticMetaData: MetaData? = nil, callStackTree: [CallStackTree]? = nil) {
                self.diagnosticMetaData = diagnosticMetaData
                self.callStackTree = callStackTree
            }

            /// The device and app state when the report was captured.
            public struct MetaData: Codable, Sendable {
                public let appVersion: String?
                public let buildVersion: String?
                public let bundleId: String?
                public let deviceType: String?
                public let osVersion: String?
                public let platformArchitecture: String?
                /// What the app was doing, e.g. `Hang` or a launch event.
                public let event: String?
                public let eventDetail: String?
                /// Bytes written, for `DISK_WRITES` signatures.
                public let writesCaused: String?

                /// Creates a `MetaData`.
                public init(
                    appVersion: String? = nil,
                    buildVersion: String? = nil,
                    bundleId: String? = nil,
                    deviceType: String? = nil,
                    osVersion: String? = nil,
                    platformArchitecture: String? = nil,
                    event: String? = nil,
                    eventDetail: String? = nil,
                    writesCaused: String? = nil
                ) {
                    self.appVersion = appVersion
                    self.buildVersion = buildVersion
                    self.bundleId = bundleId
                    self.deviceType = deviceType
                    self.osVersion = osVersion
                    self.platformArchitecture = platformArchitecture
                    self.event = event
                    self.eventDetail = eventDetail
                    self.writesCaused = writesCaused
                }
            }

            /// A set of call stacks, optionally one per thread.
            public struct CallStackTree: Codable, Sendable {
                public let callStackPerThread: Bool?
                public let callStacks: [CallStack]?

                /// Creates a `CallStackTree`.
                public init(callStackPerThread: Bool? = nil, callStacks: [CallStack]? = nil) {
                    self.callStackPerThread = callStackPerThread
                    self.callStacks = callStacks
                }

                /// One thread's stack.
                public struct CallStack: Codable, Sendable {
                    public let callStackRootFrames: [Frame]?

                    /// Creates a `CallStack`.
                    public init(callStackRootFrames: [Frame]? = nil) {
                        self.callStackRootFrames = callStackRootFrames
                    }
                }

                /// A call-stack frame.
                public struct Frame: Codable, Sendable {
                    public let binaryName: String?
                    public let symbolName: String?
                    public let fileName: String?
                    public let lineNumber: String?
                    public let address: String?
                    public let binaryUUID: String?
                    public let offsetIntoBinaryTextSegment: String?
                    public let offsetIntoSymbol: String?
                    public let rawFrame: String?
                    public let insightsCategory: String?
                    /// How many samples landed in this frame — the weight of a hang.
                    public let sampleCount: Int?
                    /// Apple's marker for the frame most likely responsible.
                    public let isBlameFrame: Bool?
                    /// The frames this one called.
                    public let subFrames: [Frame]?

                    /// Creates a `Frame`.
                    public init(
                        binaryName: String? = nil,
                        symbolName: String? = nil,
                        fileName: String? = nil,
                        lineNumber: String? = nil,
                        address: String? = nil,
                        binaryUUID: String? = nil,
                        offsetIntoBinaryTextSegment: String? = nil,
                        offsetIntoSymbol: String? = nil,
                        rawFrame: String? = nil,
                        insightsCategory: String? = nil,
                        sampleCount: Int? = nil,
                        isBlameFrame: Bool? = nil,
                        subFrames: [Frame]? = nil
                    ) {
                        self.binaryName = binaryName
                        self.symbolName = symbolName
                        self.fileName = fileName
                        self.lineNumber = lineNumber
                        self.address = address
                        self.binaryUUID = binaryUUID
                        self.offsetIntoBinaryTextSegment = offsetIntoBinaryTextSegment
                        self.offsetIntoSymbol = offsetIntoSymbol
                        self.rawFrame = rawFrame
                        self.insightsCategory = insightsCategory
                        self.sampleCount = sampleCount
                        self.isBlameFrame = isBlameFrame
                        self.subFrames = subFrames
                    }
                }
            }
        }
    }
}

/// A reader-sized view of a signature's logs.
///
/// The raw payload nests a full call-stack tree per thread per report, which is far
/// more than a caller needs (and more than an agent's context can hold). This keeps
/// the device/version context and the frames Apple blames, flattened and ranked.
public struct DiagnosticLogSummary: Codable, Sendable {
    /// The signature these logs belong to.
    public let signatureID: String?
    /// One entry per device report.
    public let reports: [Report]

    /// Creates a `DiagnosticLogSummary`.
    public init(signatureID: String?, reports: [Report]) {
        self.signatureID = signatureID
        self.reports = reports
    }

    /// One device's report, reduced to its context plus the frames worth reading.
    public struct Report: Codable, Sendable {
        public let appVersion: String?
        public let buildVersion: String?
        public let osVersion: String?
        public let deviceType: String?
        public let event: String?
        public let eventDetail: String?
        public let writesCaused: String?
        /// Frames Apple marked as responsible, deepest weight first.
        public let blameFrames: [Frame]
        /// Total frames in the report, so a caller knows how much was elided.
        public let totalFrames: Int

        /// Creates a `Report`.
        public init(
            appVersion: String?,
            buildVersion: String?,
            osVersion: String?,
            deviceType: String?,
            event: String?,
            eventDetail: String?,
            writesCaused: String?,
            blameFrames: [Frame],
            totalFrames: Int
        ) {
            self.appVersion = appVersion
            self.buildVersion = buildVersion
            self.osVersion = osVersion
            self.deviceType = deviceType
            self.event = event
            self.eventDetail = eventDetail
            self.writesCaused = writesCaused
            self.blameFrames = blameFrames
            self.totalFrames = totalFrames
        }

        /// A single frame worth showing, with the source location when Apple symbolicated it.
        public struct Frame: Codable, Sendable {
            public let symbolName: String?
            public let binaryName: String?
            public let fileName: String?
            public let lineNumber: String?
            public let sampleCount: Int?
            /// Depth in the stack, so the caller can see the shape without the tree.
            public let depth: Int

            /// Creates a `Frame`.
            public init(
                symbolName: String?,
                binaryName: String?,
                fileName: String?,
                lineNumber: String?,
                sampleCount: Int?,
                depth: Int
            ) {
                self.symbolName = symbolName
                self.binaryName = binaryName
                self.fileName = fileName
                self.lineNumber = lineNumber
                self.sampleCount = sampleCount
                self.depth = depth
            }
        }
    }
}

/// The raw `/v1/apps/{id}/perfPowerMetrics` payload (`xcodeMetrics`).
///
/// Like the diagnostics endpoint, this is not a JSON:API envelope.
public struct PerfPowerMetricsResponse: Codable, Sendable {
    public let version: String?
    public let insights: Insights?
    public let productData: [ProductData]?

    /// Creates a `PerfPowerMetricsResponse`.
    public init(version: String? = nil, insights: Insights? = nil, productData: [ProductData]? = nil) {
        self.version = version
        self.insights = insights
        self.productData = productData
    }

    /// Apple's own read on which metrics moved.
    public struct Insights: Codable, Sendable {
        /// Metrics that got worse in the latest version — the ones worth acting on.
        public let regressions: [Insight]?
        public let trendingUp: [Insight]?

        /// Creates an `Insights`.
        public init(regressions: [Insight]? = nil, trendingUp: [Insight]? = nil) {
            self.regressions = regressions
            self.trendingUp = trendingUp
        }

        /// One metric that moved between versions.
        public struct Insight: Codable, Sendable {
            public let metric: String?
            public let metricCategory: String?
            public let subSystemLabel: String?
            public let latestVersion: String?
            public let maxLatestVersionValue: Double?
            public let referenceVersions: String?
            public let highImpact: Bool?
            /// Apple's own one-line summary, e.g. "50% slower than 1.3.0".
            public let summaryString: String?
            public let populations: [Population]?

            /// Creates an `Insight`.
            public init(
                metric: String? = nil,
                metricCategory: String? = nil,
                subSystemLabel: String? = nil,
                latestVersion: String? = nil,
                maxLatestVersionValue: Double? = nil,
                referenceVersions: String? = nil,
                highImpact: Bool? = nil,
                summaryString: String? = nil,
                populations: [Population]? = nil
            ) {
                self.metric = metric
                self.metricCategory = metricCategory
                self.subSystemLabel = subSystemLabel
                self.latestVersion = latestVersion
                self.maxLatestVersionValue = maxLatestVersionValue
                self.referenceVersions = referenceVersions
                self.highImpact = highImpact
                self.summaryString = summaryString
                self.populations = populations
            }

            /// One device/percentile slice of an insight.
            public struct Population: Codable, Sendable {
                public let device: String?
                public let percentile: String?
                public let deltaPercentage: Double?
                public let latestVersionValue: Double?
                public let referenceAverageValue: Double?
                public let summaryString: String?

                /// Creates a `Population`.
                public init(
                    device: String? = nil,
                    percentile: String? = nil,
                    deltaPercentage: Double? = nil,
                    latestVersionValue: Double? = nil,
                    referenceAverageValue: Double? = nil,
                    summaryString: String? = nil
                ) {
                    self.device = device
                    self.percentile = percentile
                    self.deltaPercentage = deltaPercentage
                    self.latestVersionValue = latestVersionValue
                    self.referenceAverageValue = referenceAverageValue
                    self.summaryString = summaryString
                }
            }
        }
    }

    /// Metrics for one platform.
    public struct ProductData: Codable, Sendable {
        public let platform: String?
        public let metricCategories: [MetricCategory]?

        /// Creates a `ProductData`.
        public init(platform: String? = nil, metricCategories: [MetricCategory]? = nil) {
            self.platform = platform
            self.metricCategories = metricCategories
        }

        /// One category (`LAUNCH`, `HANG`, `MEMORY`, `DISK`, `BATTERY`, …).
        public struct MetricCategory: Codable, Sendable {
            public let identifier: String?
            public let metrics: [Metric]?

            /// Creates a `MetricCategory`.
            public init(identifier: String? = nil, metrics: [Metric]? = nil) {
                self.identifier = identifier
                self.metrics = metrics
            }

            /// One metric and every dataset (device × percentile) measured for it.
            public struct Metric: Codable, Sendable {
                public let identifier: String?
                public let unit: Unit?
                public let goalKeys: [GoalKey]?
                public let datasets: [Dataset]?

                /// Creates a `Metric`.
                public init(
                    identifier: String? = nil,
                    unit: Unit? = nil,
                    goalKeys: [GoalKey]? = nil,
                    datasets: [Dataset]? = nil
                ) {
                    self.identifier = identifier
                    self.unit = unit
                    self.goalKeys = goalKeys
                    self.datasets = datasets
                }

                /// The unit a metric's values are in.
                public struct Unit: Codable, Sendable {
                    public let identifier: String?
                    public let displayName: String?

                    /// Creates a `Unit`.
                    public init(identifier: String? = nil, displayName: String? = nil) {
                        self.identifier = identifier
                        self.displayName = displayName
                    }
                }

                /// A named band (`GOOD`, `AVERAGE`, `POOR`) and its bounds.
                public struct GoalKey: Codable, Sendable {
                    public let goalKey: String?
                    public let lowerBound: Double?
                    public let upperBound: Double?

                    /// Creates a `GoalKey`.
                    public init(goalKey: String? = nil, lowerBound: Double? = nil, upperBound: Double? = nil) {
                        self.goalKey = goalKey
                        self.lowerBound = lowerBound
                        self.upperBound = upperBound
                    }
                }

                /// One device/percentile series across app versions.
                public struct Dataset: Codable, Sendable {
                    public let filterCriteria: FilterCriteria?
                    public let points: [Point]?

                    /// Creates a `Dataset`.
                    public init(filterCriteria: FilterCriteria? = nil, points: [Point]? = nil) {
                        self.filterCriteria = filterCriteria
                        self.points = points
                    }

                    /// Which device and percentile this series covers.
                    public struct FilterCriteria: Codable, Sendable {
                        public let device: String?
                        public let deviceMarketingName: String?
                        public let percentile: String?

                        /// Creates a `FilterCriteria`.
                        public init(
                            device: String? = nil,
                            deviceMarketingName: String? = nil,
                            percentile: String? = nil
                        ) {
                            self.device = device
                            self.deviceMarketingName = deviceMarketingName
                            self.percentile = percentile
                        }
                    }

                    /// One app version's measurement.
                    public struct Point: Codable, Sendable {
                        public let version: String?
                        public let value: Double?
                        public let errorMargin: Double?
                        /// Which goal band the value falls in.
                        public let goal: String?

                        /// Creates a `Point`.
                        public init(
                            version: String? = nil,
                            value: Double? = nil,
                            errorMargin: Double? = nil,
                            goal: String? = nil
                        ) {
                            self.version = version
                            self.value = value
                            self.errorMargin = errorMargin
                            self.goal = goal
                        }
                    }
                }
            }
        }
    }
}

/// A reader-sized view of `perfPowerMetrics`.
///
/// The raw response is every percentile of every metric on every device across every
/// version — thousands of points. This keeps Apple's regression insights plus, per
/// metric, the newest measurement at each percentile.
public struct PerfPowerMetricsSummary: Codable, Sendable {
    /// Metrics Apple flags as worse than the reference versions.
    public let regressions: [Regression]
    /// The latest measurement of each metric, per percentile.
    public let metrics: [Metric]

    /// Creates a `PerfPowerMetricsSummary`.
    public init(regressions: [Regression], metrics: [Metric]) {
        self.regressions = regressions
        self.metrics = metrics
    }

    /// One flagged regression, with Apple's own summary text.
    public struct Regression: Codable, Sendable {
        public let metric: String?
        public let category: String?
        public let summary: String?
        public let highImpact: Bool?
        public let latestVersion: String?
        public let worstDeltaPercentage: Double?

        /// Creates a `Regression`.
        public init(
            metric: String?,
            category: String?,
            summary: String?,
            highImpact: Bool?,
            latestVersion: String?,
            worstDeltaPercentage: Double?
        ) {
            self.metric = metric
            self.category = category
            self.summary = summary
            self.highImpact = highImpact
            self.latestVersion = latestVersion
            self.worstDeltaPercentage = worstDeltaPercentage
        }
    }

    /// The newest point of one metric for one device/percentile slice.
    public struct Metric: Codable, Sendable {
        public let category: String?
        public let metric: String?
        public let platform: String?
        public let device: String?
        public let percentile: String?
        public let version: String?
        public let value: Double?
        public let unit: String?
        /// The goal band the value falls in, when Apple assigns one.
        public let goal: String?

        /// Creates a `Metric`.
        public init(
            category: String?,
            metric: String?,
            platform: String?,
            device: String?,
            percentile: String?,
            version: String?,
            value: Double?,
            unit: String?,
            goal: String?
        ) {
            self.category = category
            self.metric = metric
            self.platform = platform
            self.device = device
            self.percentile = percentile
            self.version = version
            self.value = value
            self.unit = unit
            self.goal = goal
        }
    }
}
