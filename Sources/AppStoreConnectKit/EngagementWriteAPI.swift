import Foundation

// MARK: - Review replies and TestFlight membership (writes)
//
// Request bodies follow Apple's docs JSON for `CustomerReviewResponseV1CreateRequest`,
// `BetaGroupBuildsLinkagesRequest`, and `BetaTesterCreateRequest`. Keys are camelCase on
// the wire, as everywhere else; `RequestEncodingTests` asserts each body.

extension AppStoreConnectClient {
    /// Publishes a reply to a customer review, replacing any reply already posted.
    ///
    /// A review holds at most one developer reply; posting again overwrites it. Apple
    /// reviews the text before it appears on the store, so the result's state is
    /// `PENDING_PUBLISH` at first.
    ///
    /// - Parameters:
    ///   - reviewID: The `customerReviews` id, from ``customerReviews(appID:rating:territory:limit:)``.
    ///   - responseBody: The reply text. It is public once published.
    /// - Returns: The created response.
    @discardableResult
    public func respondToCustomerReview(
        reviewID: String,
        responseBody: String
    ) async throws -> ASCCustomerReviewResponse {
        let body = CustomerReviewResponseCreateBody(
            data: .init(
                type: "customerReviewResponses",
                attributes: .init(responseBody: responseBody),
                relationships: .init(review: .init(data: .init(type: "customerReviews", id: reviewID)))
            )
        )
        let response: ASCResponse<ASCCustomerReviewResponse> = try await post(
            "/v1/customerReviewResponses", body: body)
        return response.data
    }

    /// Makes builds available to a TestFlight beta group.
    ///
    /// For an external group the build still needs beta app review before testers can
    /// install it; an internal group gets it once processing finishes.
    ///
    /// - Parameters:
    ///   - buildIDs: The builds to add.
    ///   - betaGroupID: The group, from ``betaGroups(appID:limit:)``.
    /// - Throws: ``ASCError/apiError(statusCode:body:)`` — a 409 or 422 usually means a
    ///   build is still processing, has expired, or lacks export-compliance answers.
    public func addBuilds(_ buildIDs: [String], toBetaGroup betaGroupID: String) async throws {
        guard !buildIDs.isEmpty else {
            throw ASCError.invalidConfiguration(reason: "Pass at least one build id to add to the beta group.")
        }
        let body = LinkagesBody(data: buildIDs.map { .init(type: "builds", id: $0) })
        let _: NoContentResponse = try await post("/v1/betaGroups/\(betaGroupID)/relationships/builds", body: body)
    }

    /// Creates a beta tester in one or more beta groups, which sends them a TestFlight
    /// invitation email.
    ///
    /// - Parameters:
    ///   - email: The tester's email address.
    ///   - firstName: Optional first name.
    ///   - lastName: Optional last name.
    ///   - betaGroupIDs: The groups to add the tester to.
    /// - Returns: The created tester.
    /// - Throws: ``ASCError/apiError(statusCode:body:)`` — a 409 usually means the
    ///   address is already a tester in one of the groups.
    @discardableResult
    public func inviteBetaTester(
        email: String,
        firstName: String? = nil,
        lastName: String? = nil,
        betaGroupIDs: [String]
    ) async throws -> ASCBetaTester {
        guard !betaGroupIDs.isEmpty else {
            throw ASCError.invalidConfiguration(reason: "Pass at least one beta group id to invite the tester to.")
        }
        let body = BetaTesterCreateBody(
            data: .init(
                type: "betaTesters",
                attributes: .init(email: email, firstName: firstName, lastName: lastName),
                relationships: .init(
                    betaGroups: .init(data: betaGroupIDs.map { .init(type: "betaGroups", id: $0) })
                )
            )
        )
        let response: ASCResponse<ASCBetaTester> = try await post("/v1/betaTesters", body: body)
        return response.data
    }
}

// MARK: - Request bodies

/// A `type`/`id` pair, the unit of every relationship in a JSON:API body.
private struct LinkageIdentifier: Encodable, Sendable {
    let type: String
    let id: String
}

/// `{"data": [{"type": …, "id": …}, …]}`, the body of a to-many relationship change.
private struct LinkagesBody: Encodable, Sendable {
    let data: [LinkageIdentifier]
}

/// `POST /v1/customerReviewResponses` body.
private struct CustomerReviewResponseCreateBody: Encodable, Sendable {
    let data: Data

    struct Data: Encodable, Sendable {
        let type: String
        let attributes: Attributes
        let relationships: Relationships

        struct Attributes: Encodable, Sendable {
            let responseBody: String
        }

        struct Relationships: Encodable, Sendable {
            let review: Review

            struct Review: Encodable, Sendable {
                let data: LinkageIdentifier
            }
        }
    }
}

/// `POST /v1/betaTesters` body. `firstName`/`lastName` are omitted when `nil`.
private struct BetaTesterCreateBody: Encodable, Sendable {
    let data: Data

    struct Data: Encodable, Sendable {
        let type: String
        let attributes: Attributes
        let relationships: Relationships

        struct Attributes: Encodable, Sendable {
            let email: String
            let firstName: String?
            let lastName: String?
        }

        struct Relationships: Encodable, Sendable {
            let betaGroups: LinkagesBody
        }
    }
}
