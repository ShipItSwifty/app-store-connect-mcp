import Foundation

// Attribute types follow Apple's docs JSON for `InAppPurchaseV2`, `SubscriptionGroup`,
// and `Subscription` rather than the field names.

/// An `inAppPurchases` (v2) resource: a consumable, non-consumable, or non-renewing
/// subscription. Auto-renewable subscriptions are ``ASCSubscription``s instead.
public struct ASCInAppPurchase: Codable, Sendable {
    /// Unique identifier for this in-app purchase.
    public let id: String
    /// In-app purchase attributes.
    public let attributes: Attributes?

    /// Creates an `ASCInAppPurchase`.
    public init(id: String, attributes: Attributes? = nil) {
        self.id = id
        self.attributes = attributes
    }

    /// Attributes of an in-app purchase.
    public struct Attributes: Codable, Sendable {
        /// The reference name shown in App Store Connect.
        public let name: String?
        /// The product identifier the app passes to StoreKit.
        public let productId: String?
        /// `CONSUMABLE`, `NON_CONSUMABLE`, or `NON_RENEWING_SUBSCRIPTION`.
        public let inAppPurchaseType: String?
        /// `MISSING_METADATA`, `READY_TO_SUBMIT`, `WAITING_FOR_REVIEW`, `IN_REVIEW`,
        /// `DEVELOPER_ACTION_NEEDED`, `REJECTED`, `APPROVED`, `DEVELOPER_REMOVED_FROM_SALE`, …
        public let state: String?
        /// The note for App Review.
        public let reviewNote: String?
        /// Whether Family Sharing is enabled.
        public let familySharable: Bool?
        /// Whether Apple hosts the purchase's downloadable content.
        public let contentHosting: Bool?

        /// Creates `ASCInAppPurchase.Attributes`.
        public init(
            name: String? = nil,
            productId: String? = nil,
            inAppPurchaseType: String? = nil,
            state: String? = nil,
            reviewNote: String? = nil,
            familySharable: Bool? = nil,
            contentHosting: Bool? = nil
        ) {
            self.name = name
            self.productId = productId
            self.inAppPurchaseType = inAppPurchaseType
            self.state = state
            self.reviewNote = reviewNote
            self.familySharable = familySharable
            self.contentHosting = contentHosting
        }
    }
}

/// A `subscriptionGroups` resource: the set of auto-renewable subscriptions a
/// customer can hold only one of at a time.
public struct ASCSubscriptionGroup: Codable, Sendable {
    /// Unique identifier for this group.
    public let id: String
    /// Group attributes.
    public let attributes: Attributes?

    /// Creates an `ASCSubscriptionGroup`.
    public init(id: String, attributes: Attributes? = nil) {
        self.id = id
        self.attributes = attributes
    }

    /// Attributes of a subscription group.
    public struct Attributes: Codable, Sendable {
        /// The reference name shown in App Store Connect.
        public let referenceName: String?

        /// Creates `ASCSubscriptionGroup.Attributes`.
        public init(referenceName: String? = nil) {
            self.referenceName = referenceName
        }
    }
}

/// A `subscriptions` resource: one auto-renewable subscription in a group.
public struct ASCSubscription: Codable, Sendable {
    /// Unique identifier for this subscription.
    public let id: String
    /// Subscription attributes.
    public let attributes: Attributes?

    /// Creates an `ASCSubscription`.
    public init(id: String, attributes: Attributes? = nil) {
        self.id = id
        self.attributes = attributes
    }

    /// Attributes of an auto-renewable subscription.
    public struct Attributes: Codable, Sendable {
        /// The reference name shown in App Store Connect.
        public let name: String?
        /// The product identifier the app passes to StoreKit.
        public let productId: String?
        /// Review state, as for ``ASCInAppPurchase/Attributes/state``.
        public let state: String?
        /// `ONE_WEEK`, `ONE_MONTH`, `TWO_MONTHS`, `THREE_MONTHS`, `SIX_MONTHS`, `ONE_YEAR`.
        public let subscriptionPeriod: String?
        /// The rank within its group; `1` is the highest level of service.
        public let groupLevel: Int?
        /// Whether Family Sharing is enabled.
        public let familySharable: Bool?
        /// The note for App Review.
        public let reviewNote: String?

        /// Creates `ASCSubscription.Attributes`.
        public init(
            name: String? = nil,
            productId: String? = nil,
            state: String? = nil,
            subscriptionPeriod: String? = nil,
            groupLevel: Int? = nil,
            familySharable: Bool? = nil,
            reviewNote: String? = nil
        ) {
            self.name = name
            self.productId = productId
            self.state = state
            self.subscriptionPeriod = subscriptionPeriod
            self.groupLevel = groupLevel
            self.familySharable = familySharable
            self.reviewNote = reviewNote
        }
    }
}

/// A subscription group together with the subscriptions inside it.
public struct ASCSubscriptionGroupDetail: Codable, Sendable {
    /// The group.
    public let group: ASCSubscriptionGroup
    /// The group's subscriptions, highest level of service first.
    public let subscriptions: [ASCSubscription]

    /// Creates an `ASCSubscriptionGroupDetail`.
    public init(group: ASCSubscriptionGroup, subscriptions: [ASCSubscription]) {
        self.group = group
        self.subscriptions = subscriptions
    }
}
