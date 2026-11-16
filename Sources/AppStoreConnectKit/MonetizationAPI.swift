import Foundation

// MARK: - In-app purchases and subscriptions (read)

extension AppStoreConnectClient {
    /// Lists an app's in-app purchases: consumables, non-consumables, and non-renewing
    /// subscriptions. Auto-renewable subscriptions live in subscription groups; see
    /// ``subscriptionCatalog(appID:state:limit:)``.
    ///
    /// - Parameters:
    ///   - appID: App Store Connect app id.
    ///   - type: Optional `filter[inAppPurchaseType]` — `CONSUMABLE`, `NON_CONSUMABLE`,
    ///     or `NON_RENEWING_SUBSCRIPTION`.
    ///   - state: Optional `filter[state]`, e.g. `DEVELOPER_ACTION_NEEDED` or `REJECTED`.
    ///   - limit: Maximum purchases to return across all pages.
    public func inAppPurchases(
        appID: String,
        type: String? = nil,
        state: String? = nil,
        limit: Int = 200
    ) async throws -> ASCListResponse<ASCInAppPurchase> {
        var query: [String: String] = [:]
        if let type { query["filter[inAppPurchaseType]"] = type }
        if let state { query["filter[state]"] = state }
        return try await getAll("/v1/apps/\(appID)/inAppPurchasesV2", query: query, limit: limit)
    }

    /// Lists an app's subscription groups.
    public func subscriptionGroups(appID: String, limit: Int = 200) async throws -> ASCListResponse<ASCSubscriptionGroup> {
        try await getAll("/v1/apps/\(appID)/subscriptionGroups", limit: limit)
    }

    /// Lists the auto-renewable subscriptions in one group.
    ///
    /// - Parameters:
    ///   - groupID: The subscription group id.
    ///   - state: Optional `filter[state]`.
    ///   - limit: Maximum subscriptions to return across all pages.
    public func subscriptions(
        groupID: String,
        state: String? = nil,
        limit: Int = 200
    ) async throws -> ASCListResponse<ASCSubscription> {
        var query: [String: String] = [:]
        if let state { query["filter[state]"] = state }
        return try await getAll("/v1/subscriptionGroups/\(groupID)/subscriptions", query: query, limit: limit)
    }

    /// Every subscription group of an app with the subscriptions inside it, each group's
    /// subscriptions ordered by `groupLevel` (highest level of service first).
    ///
    /// Costs one request for the groups plus one per group.
    ///
    /// - Parameters:
    ///   - appID: App Store Connect app id.
    ///   - state: Optional `filter[state]` applied to the subscriptions. Groups whose
    ///     subscriptions all fail the filter are still listed, with none inside.
    ///   - limit: Maximum subscriptions to return per group.
    public func subscriptionCatalog(
        appID: String,
        state: String? = nil,
        limit: Int = 200
    ) async throws -> [ASCSubscriptionGroupDetail] {
        var catalog: [ASCSubscriptionGroupDetail] = []
        for group in try await subscriptionGroups(appID: appID).data {
            let subscriptions = try await self.subscriptions(groupID: group.id, state: state, limit: limit).data
            let ordered = subscriptions.sorted {
                ($0.attributes?.groupLevel ?? Int.max) < ($1.attributes?.groupLevel ?? Int.max)
            }
            catalog.append(ASCSubscriptionGroupDetail(group: group, subscriptions: ordered))
        }
        return catalog
    }
}
