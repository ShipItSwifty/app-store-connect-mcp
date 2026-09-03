import Foundation

// MARK: - Generic Response Wrappers

/// Generic single-resource response wrapper for App Store Connect API responses.
///
/// All ASC API responses for single resources follow the `{ "data": {...} }` envelope.
public struct ASCResponse<T: Codable & Sendable>: Codable, Sendable where T: Codable {
    /// The primary data payload.
    public let data: T

    /// Creates an `ASCResponse`.
    public init(data: T) {
        self.data = data
    }
}

/// Generic list response wrapper for App Store Connect API list endpoints.
///
/// All ASC API responses for resource collections follow the `{ "data": [...] }` envelope,
/// optionally including `links` for pagination.
public struct ASCListResponse<T: Codable & Sendable>: Codable, Sendable {
    /// Array of resources returned by the endpoint.
    public let data: [T]

    /// Pagination links.
    public let links: PagedLinks?

    /// Creates an `ASCListResponse`.
    public init(data: [T], links: PagedLinks? = nil) {
        self.data = data
        self.links = links
    }
}

/// Pagination links included in list API responses.
public struct PagedLinks: Codable, Sendable {
    /// URL for the current page.
    public let `self`: String?

    /// URL for the next page of results.
    public let next: String?

    /// URL for the first page of results.
    public let first: String?

    /// Creates a `PagedLinks`.
    public init(self selfURL: String? = nil, next: String? = nil, first: String? = nil) {
        self.`self` = selfURL
        self.next = next
        self.first = first
    }
}

// MARK: - App

/// An iOS or macOS app registered in App Store Connect.
public struct ASCApp: Codable, Sendable {
    /// Unique identifier for this app resource.
    public let id: String

    /// App attributes.
    public let attributes: Attributes?

    /// Creates an `ASCApp`.
    public init(id: String, attributes: Attributes? = nil) {
        self.id = id
        self.attributes = attributes
    }

    /// Attributes of an App Store Connect app.
    public struct Attributes: Codable, Sendable {
        /// The app's bundle identifier (e.g. `com.example.myapp`).
        public let bundleId: String?

        /// The app's display name on the App Store.
        public let name: String?

        /// The app's primary language (e.g. `en-US`).
        public let primaryLocale: String?

        /// Whether the app is (or ever was) in the Kids category.
        public let isOrEverWasMadeForKids: Bool?

        /// The app's SKU, as entered when the record was created.
        public let sku: String?

        /// Creates `ASCApp.Attributes`.
        public init(
            bundleId: String? = nil,
            name: String? = nil,
            primaryLocale: String? = nil,
            isOrEverWasMadeForKids: Bool? = nil,
            sku: String? = nil
        ) {
            self.bundleId = bundleId
            self.name = name
            self.primaryLocale = primaryLocale
            self.isOrEverWasMadeForKids = isOrEverWasMadeForKids
            self.sku = sku
        }
    }
}

// MARK: - Build

/// A processed build associated with an app in App Store Connect.
public struct ASCBuild: Codable, Sendable {
    /// Unique identifier for this build.
    public let id: String

    /// Build attributes.
    public let attributes: Attributes?

    /// Creates an `ASCBuild`.
    public init(id: String, attributes: Attributes? = nil) {
        self.id = id
        self.attributes = attributes
    }

    /// Attributes of an App Store Connect build.
    public struct Attributes: Codable, Sendable {
        /// The build version string (e.g. `"142"`).
        public let version: String?

        /// Current processing state.
        public let processingState: String?

        /// Whether the build has expired.
        public let expired: Bool?

        /// Date when the build was uploaded.
        public let uploadedDate: String?

        /// When TestFlight will stop distributing this build (90 days after upload).
        public let expirationDate: String?

        /// The minimum OS version the build supports.
        public let minOsVersion: String?

        /// `APP_STORE_ELIGIBLE` or `INTERNAL_ONLY`. An `INTERNAL_ONLY` build can never be
        /// attached to an App Store version — the relationship rejects it with a
        /// `409 ENTITY_ERROR`, which is a common and otherwise baffling release failure.
        public let buildAudienceType: String?

        /// Export-compliance answer recorded for the build. `nil` means unanswered, which
        /// blocks TestFlight external distribution and App Store submission.
        public let usesNonExemptEncryption: Bool?

        /// Creates `ASCBuild.Attributes`.
        public init(
            version: String? = nil,
            processingState: String? = nil,
            expired: Bool? = nil,
            uploadedDate: String? = nil,
            expirationDate: String? = nil,
            minOsVersion: String? = nil,
            buildAudienceType: String? = nil,
            usesNonExemptEncryption: Bool? = nil
        ) {
            self.version = version
            self.processingState = processingState
            self.expired = expired
            self.uploadedDate = uploadedDate
            self.expirationDate = expirationDate
            self.minOsVersion = minOsVersion
            self.buildAudienceType = buildAudienceType
            self.usesNonExemptEncryption = usesNonExemptEncryption
        }
    }
}

// MARK: - Beta Group

/// A TestFlight beta testing group.
public struct ASCBetaGroup: Codable, Sendable {
    /// Unique identifier for this beta group.
    public let id: String

    /// Beta group attributes.
    public let attributes: Attributes?

    /// Creates an `ASCBetaGroup`.
    public init(id: String, attributes: Attributes? = nil) {
        self.id = id
        self.attributes = attributes
    }

    /// Attributes of a TestFlight beta group.
    public struct Attributes: Codable, Sendable {
        /// The name of the beta group.
        public let name: String?

        /// The group's public TestFlight invite URL, when one is enabled.
        ///
        /// Apple sends this as a URL *string*, not a flag — decoding it as `Bool`
        /// threw `typeMismatch` for every group with a public link enabled.
        public let publicLink: String?

        /// Whether the public link is enabled.
        public let publicLinkEnabled: Bool?

        /// Cap on redemptions of the public link, when one is set.
        public let publicLinkLimit: Int?

        /// Whether this is an internal (App Store Connect user) group.
        public let isInternalGroup: Bool?

        /// Whether testers in this group can send feedback.
        public let feedbackEnabled: Bool?

        /// Whether the group automatically receives every new build.
        public let hasAccessToAllBuilds: Bool?

        public let createdDate: String?

        /// Creates `ASCBetaGroup.Attributes`.
        public init(
            name: String? = nil,
            publicLink: String? = nil,
            publicLinkEnabled: Bool? = nil,
            publicLinkLimit: Int? = nil,
            isInternalGroup: Bool? = nil,
            feedbackEnabled: Bool? = nil,
            hasAccessToAllBuilds: Bool? = nil,
            createdDate: String? = nil
        ) {
            self.name = name
            self.publicLink = publicLink
            self.publicLinkEnabled = publicLinkEnabled
            self.publicLinkLimit = publicLinkLimit
            self.isInternalGroup = isInternalGroup
            self.feedbackEnabled = feedbackEnabled
            self.hasAccessToAllBuilds = hasAccessToAllBuilds
            self.createdDate = createdDate
        }
    }
}

// MARK: - Beta Tester

/// A TestFlight beta tester.
public struct ASCBetaTester: Codable, Sendable {
    /// Unique identifier for this tester.
    public let id: String

    /// Tester attributes.
    public let attributes: Attributes?

    /// Creates an `ASCBetaTester`.
    public init(id: String, attributes: Attributes? = nil) {
        self.id = id
        self.attributes = attributes
    }

    /// Attributes of a TestFlight beta tester.
    public struct Attributes: Codable, Sendable {
        /// The tester's first name.
        public let firstName: String?

        /// The tester's last name.
        public let lastName: String?

        /// The tester's email address.
        public let email: String?

        /// Current invite type (`EMAIL`, `PUBLIC_LINK`).
        public let inviteType: String?

        /// `INVITED`, `ACCEPTED`, `INSTALLED`, `NOT_INVITED`, `REVOKED`.
        public let state: String?

        /// Creates `ASCBetaTester.Attributes`.
        public init(
            firstName: String? = nil,
            lastName: String? = nil,
            email: String? = nil,
            inviteType: String? = nil,
            state: String? = nil
        ) {
            self.firstName = firstName
            self.lastName = lastName
            self.email = email
            self.inviteType = inviteType
            self.state = state
        }
    }
}
