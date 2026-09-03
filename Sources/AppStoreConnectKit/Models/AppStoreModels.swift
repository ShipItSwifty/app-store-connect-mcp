import Foundation

// MARK: - App Store & TestFlight read models
//
// Public decoding shapes for the App Store / TestFlight resources the read API in
// `AppStoreAPI.swift` returns. Attribute names match Apple's wire format exactly
// (camelCase, no key strategy) and every attribute is optional: App Store Connect
// only returns what a `fields[…]` selection asks for, and adds attributes over time.

/// An `appStoreVersions` resource — one version of an app's App Store listing.
public struct ASCAppStoreVersion: Codable, Sendable {
    /// Unique identifier for this version.
    public let id: String
    /// Version attributes.
    public let attributes: Attributes?

    /// Creates an `ASCAppStoreVersion`.
    public init(id: String, attributes: Attributes? = nil) {
        self.id = id
        self.attributes = attributes
    }

    /// Attributes of an App Store version.
    public struct Attributes: Codable, Sendable {
        /// The marketing version string (e.g. `"1.4.0"`).
        public let versionString: String?
        /// `IOS`, `MAC_OS`, `TV_OS`, `VISION_OS`.
        public let platform: String?
        /// The legacy review state. Newer tenants populate ``appVersionState`` instead —
        /// read them together with ``ASCAppStoreVersion/state``.
        public let appStoreState: String?
        /// The current review state (`PREPARE_FOR_SUBMISSION`, `WAITING_FOR_REVIEW`,
        /// `IN_REVIEW`, `REJECTED`, `READY_FOR_DISTRIBUTION`, …).
        public let appVersionState: String?
        /// `MANUAL`, `AFTER_APPROVAL`, or `SCHEDULED`.
        public let releaseType: String?
        /// Set when `releaseType` is `SCHEDULED`.
        public let earliestReleaseDate: String?
        /// Whether the version is downloadable from the App Store.
        public let downloadable: Bool?
        public let copyright: String?
        public let createdDate: String?

        /// Creates `ASCAppStoreVersion.Attributes`.
        public init(
            versionString: String? = nil,
            platform: String? = nil,
            appStoreState: String? = nil,
            appVersionState: String? = nil,
            releaseType: String? = nil,
            earliestReleaseDate: String? = nil,
            downloadable: Bool? = nil,
            copyright: String? = nil,
            createdDate: String? = nil
        ) {
            self.versionString = versionString
            self.platform = platform
            self.appStoreState = appStoreState
            self.appVersionState = appVersionState
            self.releaseType = releaseType
            self.earliestReleaseDate = earliestReleaseDate
            self.downloadable = downloadable
            self.copyright = copyright
            self.createdDate = createdDate
        }
    }

    /// The version's review state, preferring whichever field this tenant populates.
    public var state: String? {
        attributes?.appVersionState ?? attributes?.appStoreState
    }
}

/// An `appStoreVersionLocalizations` resource — the store listing text for one locale.
public struct ASCAppStoreVersionLocalization: Codable, Sendable {
    /// Unique identifier for this localization.
    public let id: String
    /// Localization attributes.
    public let attributes: Attributes?

    /// Creates an `ASCAppStoreVersionLocalization`.
    public init(id: String, attributes: Attributes? = nil) {
        self.id = id
        self.attributes = attributes
    }

    /// Attributes of an App Store version localization.
    public struct Attributes: Codable, Sendable {
        public let locale: String?
        public let description: String?
        public let keywords: String?
        public let whatsNew: String?
        public let promotionalText: String?
        public let marketingUrl: String?
        public let supportUrl: String?

        /// Creates `ASCAppStoreVersionLocalization.Attributes`.
        public init(
            locale: String? = nil,
            description: String? = nil,
            keywords: String? = nil,
            whatsNew: String? = nil,
            promotionalText: String? = nil,
            marketingUrl: String? = nil,
            supportUrl: String? = nil
        ) {
            self.locale = locale
            self.description = description
            self.keywords = keywords
            self.whatsNew = whatsNew
            self.promotionalText = promotionalText
            self.marketingUrl = marketingUrl
            self.supportUrl = supportUrl
        }
    }
}

/// A `buildBetaDetails` resource — a build's TestFlight distribution state.
///
/// This is the resource that answers "why can't my testers see this build?":
/// `internalBuildState` / `externalBuildState` carry `WAITING_FOR_BETA_REVIEW`,
/// `IN_BETA_REVIEW`, `REJECTED`, `IN_EXPORT_COMPLIANCE_REVIEW`, `READY_FOR_TESTING`, …
public struct ASCBuildBetaDetail: Codable, Sendable {
    /// Unique identifier for this resource.
    public let id: String
    /// Beta detail attributes.
    public let attributes: Attributes?

    /// Creates an `ASCBuildBetaDetail`.
    public init(id: String, attributes: Attributes? = nil) {
        self.id = id
        self.attributes = attributes
    }

    /// Attributes of a build's beta detail.
    public struct Attributes: Codable, Sendable {
        /// TestFlight state for internal testers.
        public let internalBuildState: String?
        /// TestFlight state for external testers (drives Beta App Review).
        public let externalBuildState: String?
        /// Whether testers are notified automatically when the build is approved.
        public let autoNotifyEnabled: Bool?

        /// Creates `ASCBuildBetaDetail.Attributes`.
        public init(
            internalBuildState: String? = nil,
            externalBuildState: String? = nil,
            autoNotifyEnabled: Bool? = nil
        ) {
            self.internalBuildState = internalBuildState
            self.externalBuildState = externalBuildState
            self.autoNotifyEnabled = autoNotifyEnabled
        }
    }
}

/// A `betaBuildLocalizations` resource — the "What to Test" text for one locale.
public struct ASCBetaBuildLocalization: Codable, Sendable {
    /// Unique identifier for this localization.
    public let id: String
    /// Localization attributes.
    public let attributes: Attributes?

    /// Creates an `ASCBetaBuildLocalization`.
    public init(id: String, attributes: Attributes? = nil) {
        self.id = id
        self.attributes = attributes
    }

    /// Attributes of a beta build localization.
    public struct Attributes: Codable, Sendable {
        public let locale: String?
        /// The "What to Test" notes shown to testers.
        public let whatsNew: String?

        /// Creates `ASCBetaBuildLocalization.Attributes`.
        public init(locale: String? = nil, whatsNew: String? = nil) {
            self.locale = locale
            self.whatsNew = whatsNew
        }
    }
}

/// A `customerReviews` resource — one App Store review written by a customer.
public struct ASCCustomerReview: Codable, Sendable {
    /// Unique identifier for this review.
    public let id: String
    /// Review attributes.
    public let attributes: Attributes?

    /// Creates an `ASCCustomerReview`.
    public init(id: String, attributes: Attributes? = nil) {
        self.id = id
        self.attributes = attributes
    }

    /// Attributes of a customer review.
    public struct Attributes: Codable, Sendable {
        /// Star rating, `1...5`.
        public let rating: Int?
        public let title: String?
        public let body: String?
        public let reviewerNickname: String?
        /// ISO 3166-1 alpha-3 storefront code (e.g. `USA`).
        public let territory: String?
        public let createdDate: String?

        /// Creates `ASCCustomerReview.Attributes`.
        public init(
            rating: Int? = nil,
            title: String? = nil,
            body: String? = nil,
            reviewerNickname: String? = nil,
            territory: String? = nil,
            createdDate: String? = nil
        ) {
            self.rating = rating
            self.title = title
            self.body = body
            self.reviewerNickname = reviewerNickname
            self.territory = territory
            self.createdDate = createdDate
        }
    }
}

/// A TestFlight feedback submission — a crash report or a screenshot with a comment.
///
/// `betaFeedbackCrashSubmissions` and `betaFeedbackScreenshotSubmissions` share every
/// attribute except the screenshot payload, so one shape decodes both.
public struct ASCBetaFeedback: Codable, Sendable {
    /// Unique identifier for this submission.
    public let id: String
    /// Feedback attributes.
    public let attributes: Attributes?

    /// Creates an `ASCBetaFeedback`.
    public init(id: String, attributes: Attributes? = nil) {
        self.id = id
        self.attributes = attributes
    }

    /// Attributes of a TestFlight feedback submission.
    public struct Attributes: Codable, Sendable {
        /// The tester's written feedback, when they left any.
        public let comment: String?
        public let email: String?
        public let createdDate: String?
        public let deviceModel: String?
        public let osVersion: String?
        public let locale: String?
        public let timeZone: String?
        /// `IOS`, `MAC_OS`, `TV_OS`, `VISION_OS`.
        public let appPlatform: String?
        public let devicePlatform: String?
        public let deviceFamily: String?
        public let architecture: String?
        /// The bundle id of the build the feedback came from.
        public let buildBundleId: String?
        /// How long the app had been running when the feedback was submitted.
        public let appUptimeInMilliseconds: Int?
        public let batteryPercentage: Int?
        public let diskBytesAvailable: Int?
        public let diskBytesTotal: Int?
        public let connectionType: String?
        /// Screenshot images — screenshot submissions only.
        public let screenshots: [Screenshot]?

        /// Creates `ASCBetaFeedback.Attributes`.
        public init(
            comment: String? = nil,
            email: String? = nil,
            createdDate: String? = nil,
            deviceModel: String? = nil,
            osVersion: String? = nil,
            locale: String? = nil,
            timeZone: String? = nil,
            appPlatform: String? = nil,
            devicePlatform: String? = nil,
            deviceFamily: String? = nil,
            architecture: String? = nil,
            buildBundleId: String? = nil,
            appUptimeInMilliseconds: Int? = nil,
            batteryPercentage: Int? = nil,
            diskBytesAvailable: Int? = nil,
            diskBytesTotal: Int? = nil,
            connectionType: String? = nil,
            screenshots: [Screenshot]? = nil
        ) {
            self.comment = comment
            self.email = email
            self.createdDate = createdDate
            self.deviceModel = deviceModel
            self.osVersion = osVersion
            self.locale = locale
            self.timeZone = timeZone
            self.appPlatform = appPlatform
            self.devicePlatform = devicePlatform
            self.deviceFamily = deviceFamily
            self.architecture = architecture
            self.buildBundleId = buildBundleId
            self.appUptimeInMilliseconds = appUptimeInMilliseconds
            self.batteryPercentage = batteryPercentage
            self.diskBytesAvailable = diskBytesAvailable
            self.diskBytesTotal = diskBytesTotal
            self.connectionType = connectionType
            self.screenshots = screenshots
        }

        /// One screenshot attached to a feedback submission.
        public struct Screenshot: Codable, Sendable {
            /// Time-limited download URL for the image.
            public let url: String?
            public let fileName: String?
            public let fileSize: Int?

            /// Creates a `Screenshot`.
            public init(url: String? = nil, fileName: String? = nil, fileSize: Int? = nil) {
                self.url = url
                self.fileName = fileName
                self.fileSize = fileSize
            }
        }
    }
}

/// An `appStoreVersionPhasedReleases` resource — the staged rollout of a version.
public struct ASCPhasedRelease: Codable, Sendable {
    /// Unique identifier for this phased release.
    public let id: String
    /// Phased-release attributes.
    public let attributes: Attributes?

    /// Creates an `ASCPhasedRelease`.
    public init(id: String, attributes: Attributes? = nil) {
        self.id = id
        self.attributes = attributes
    }

    /// Attributes of a phased release.
    public struct Attributes: Codable, Sendable {
        /// `INACTIVE`, `ACTIVE`, `PAUSED`, or `COMPLETE`.
        public let phasedReleaseState: String?
        /// Day 1–7 of Apple's fixed 1/2/5/10/20/50/100% schedule.
        public let currentDayNumber: Int?
        public let startDate: String?
        /// Seconds the rollout has spent paused.
        public let totalPauseDuration: Int?

        /// Creates `ASCPhasedRelease.Attributes`.
        public init(
            phasedReleaseState: String? = nil,
            currentDayNumber: Int? = nil,
            startDate: String? = nil,
            totalPauseDuration: Int? = nil
        ) {
            self.phasedReleaseState = phasedReleaseState
            self.currentDayNumber = currentDayNumber
            self.startDate = startDate
            self.totalPauseDuration = totalPauseDuration
        }
    }

    /// The share of users Apple has released to on ``Attributes/currentDayNumber``.
    ///
    /// The schedule is fixed and not returned by the API, so it is applied here rather
    /// than left for every caller to remember.
    public var percentageOfUsers: Int? {
        guard let day = attributes?.currentDayNumber, day >= 1 else { return nil }
        let schedule = [1, 2, 5, 10, 20, 50, 100]
        return day <= schedule.count ? schedule[day - 1] : 100
    }
}

/// An `appStoreReviewDetails` or `betaAppReviewDetails` resource — the contact and
/// demo-account information App Review is given.
///
/// Both resources carry identical attributes, so one shape decodes either. A missing
/// demo account on an app that needs a login is a routine rejection cause.
public struct ASCReviewDetail: Codable, Sendable {
    /// Unique identifier for this resource.
    public let id: String
    /// Review-detail attributes.
    public let attributes: Attributes?

    /// Creates an `ASCReviewDetail`.
    public init(id: String, attributes: Attributes? = nil) {
        self.id = id
        self.attributes = attributes
    }

    /// Attributes of a review detail.
    ///
    /// The demo account *password* is deliberately not modelled: it is a credential,
    /// and nothing this package does needs to read one back.
    public struct Attributes: Codable, Sendable {
        public let contactFirstName: String?
        public let contactLastName: String?
        public let contactEmail: String?
        public let contactPhone: String?
        public let demoAccountName: String?
        /// Whether the app requires a demo account for review.
        public let demoAccountRequired: Bool?
        /// Free-text notes shown to the reviewer.
        public let notes: String?

        /// Creates `ASCReviewDetail.Attributes`.
        public init(
            contactFirstName: String? = nil,
            contactLastName: String? = nil,
            contactEmail: String? = nil,
            contactPhone: String? = nil,
            demoAccountName: String? = nil,
            demoAccountRequired: Bool? = nil,
            notes: String? = nil
        ) {
            self.contactFirstName = contactFirstName
            self.contactLastName = contactLastName
            self.contactEmail = contactEmail
            self.contactPhone = contactPhone
            self.demoAccountName = demoAccountName
            self.demoAccountRequired = demoAccountRequired
            self.notes = notes
        }
    }
}

/// An `appInfos` resource — the app-level (not version-level) listing state:
/// categories, content rights, and age rating.
public struct ASCAppInfo: Codable, Sendable {
    /// Unique identifier for this app info.
    public let id: String
    /// App-info attributes.
    public let attributes: Attributes?

    /// Creates an `ASCAppInfo`.
    public init(id: String, attributes: Attributes? = nil) {
        self.id = id
        self.attributes = attributes
    }

    /// Attributes of an app info.
    public struct Attributes: Codable, Sendable {
        /// The state of this app-info record (`PREPARE_FOR_SUBMISSION`, `REJECTED`, …).
        /// App-level metadata is reviewed separately from a version, which is why an
        /// app can be `METADATA_REJECTED` while the version itself looks fine.
        public let state: String?
        public let appStoreState: String?
        /// The computed rating (`FOUR_PLUS`, `SEVENTEEN_PLUS`, …).
        public let appStoreAgeRating: String?
        public let kidsAgeBand: String?
        public let brazilAgeRatingV2: String?
        public let koreaAgeRating: String?
        public let australiaAgeRating: String?
        public let franceAgeRating: String?

        /// Creates `ASCAppInfo.Attributes`.
        public init(
            state: String? = nil,
            appStoreState: String? = nil,
            appStoreAgeRating: String? = nil,
            kidsAgeBand: String? = nil,
            brazilAgeRatingV2: String? = nil,
            koreaAgeRating: String? = nil,
            australiaAgeRating: String? = nil,
            franceAgeRating: String? = nil
        ) {
            self.state = state
            self.appStoreState = appStoreState
            self.appStoreAgeRating = appStoreAgeRating
            self.kidsAgeBand = kidsAgeBand
            self.brazilAgeRatingV2 = brazilAgeRatingV2
            self.koreaAgeRating = koreaAgeRating
            self.australiaAgeRating = australiaAgeRating
            self.franceAgeRating = franceAgeRating
        }
    }
}

/// A `certificates` resource — a signing certificate and, importantly, its expiry.
public struct ASCCertificate: Codable, Sendable {
    /// Unique identifier for this certificate.
    public let id: String
    /// Certificate attributes.
    public let attributes: Attributes?

    /// Creates an `ASCCertificate`.
    public init(id: String, attributes: Attributes? = nil) {
        self.id = id
        self.attributes = attributes
    }

    /// Attributes of a certificate. `certificateContent` (the DER payload) is omitted:
    /// nothing here installs certificates, and it would dwarf the fields that matter.
    public struct Attributes: Codable, Sendable {
        public let name: String?
        public let displayName: String?
        /// `DEVELOPMENT`, `DISTRIBUTION`, `IOS_DISTRIBUTION`, …
        public let certificateType: String?
        public let platform: String?
        public let serialNumber: String?
        public let expirationDate: String?

        /// Creates `ASCCertificate.Attributes`.
        public init(
            name: String? = nil,
            displayName: String? = nil,
            certificateType: String? = nil,
            platform: String? = nil,
            serialNumber: String? = nil,
            expirationDate: String? = nil
        ) {
            self.name = name
            self.displayName = displayName
            self.certificateType = certificateType
            self.platform = platform
            self.serialNumber = serialNumber
            self.expirationDate = expirationDate
        }
    }
}

/// A `profiles` resource — a provisioning profile, its state, and its expiry.
public struct ASCProfile: Codable, Sendable {
    /// Unique identifier for this profile.
    public let id: String
    /// Profile attributes.
    public let attributes: Attributes?

    /// Creates an `ASCProfile`.
    public init(id: String, attributes: Attributes? = nil) {
        self.id = id
        self.attributes = attributes
    }

    /// Attributes of a provisioning profile. `profileContent` (the encoded profile) is
    /// omitted for the same reason as `certificateContent`.
    public struct Attributes: Codable, Sendable {
        public let name: String?
        /// `ACTIVE` or `INVALID`. A profile goes `INVALID` when a certificate or device
        /// it references is revoked — the usual cause of a sudden code-signing failure.
        public let profileState: String?
        /// `IOS_APP_STORE`, `IOS_APP_DEVELOPMENT`, `MAC_APP_STORE`, …
        public let profileType: String?
        public let platform: String?
        public let uuid: String?
        public let createdDate: String?
        public let expirationDate: String?

        /// Creates `ASCProfile.Attributes`.
        public init(
            name: String? = nil,
            profileState: String? = nil,
            profileType: String? = nil,
            platform: String? = nil,
            uuid: String? = nil,
            createdDate: String? = nil,
            expirationDate: String? = nil
        ) {
            self.name = name
            self.profileState = profileState
            self.profileType = profileType
            self.platform = platform
            self.uuid = uuid
            self.createdDate = createdDate
            self.expirationDate = expirationDate
        }
    }
}

/// The signing assets a team has, with the ones that will stop a build called out.
public struct SigningAssetsReport: Codable, Sendable {
    public let certificates: [ASCCertificate]
    public let profiles: [ASCProfile]
    /// Certificates and profiles already expired, or expiring within the warning window.
    public let expiringSoon: [Expiring]
    /// Profiles Apple has marked `INVALID`, which fail signing immediately.
    public let invalidProfiles: [String]

    /// Creates a `SigningAssetsReport`.
    public init(
        certificates: [ASCCertificate],
        profiles: [ASCProfile],
        expiringSoon: [Expiring],
        invalidProfiles: [String]
    ) {
        self.certificates = certificates
        self.profiles = profiles
        self.expiringSoon = expiringSoon
        self.invalidProfiles = invalidProfiles
    }

    /// One asset that has expired or is about to.
    public struct Expiring: Codable, Sendable {
        /// `certificate` or `profile`.
        public let kind: String
        public let id: String
        public let name: String?
        public let expirationDate: String?
        /// Negative once the asset has already expired.
        public let daysRemaining: Int?

        /// Creates an `Expiring`.
        public init(kind: String, id: String, name: String?, expirationDate: String?, daysRemaining: Int?) {
            self.kind = kind
            self.id = id
            self.name = name
            self.expirationDate = expirationDate
            self.daysRemaining = daysRemaining
        }
    }
}
