import Foundation
import Testing

@testable import AppStoreConnectKit

@Suite("ASCError")
struct ASCErrorTests {
    private struct Underlying: LocalizedError {
        var errorDescription: String? { "the underlying reason" }
    }

    @Test("apiError description includes the status code and body")
    func apiErrorDescription() {
        let error = ASCError.apiError(statusCode: 429, body: "rate limited")
        #expect(error.errorDescription == "App Store Connect API error (429): rate limited")
    }

    @Test("apiError description surfaces errors[0].detail from a JSON:API body verbatim")
    func apiErrorSurfacesJSONAPIDetail() {
        let body = """
            {"errors":[{"status":"409","code":"ENTITY_ERROR.RELATIONSHIP.INVALID",\
            "title":"The provided entity includes a relationship with an invalid value",\
            "detail":"The specified pre-release build could not be added."}]}
            """
        let error = ASCError.apiError(statusCode: 409, body: body)
        let description = error.errorDescription ?? ""
        #expect(description.hasPrefix("App Store Connect API error (409):"))
        #expect(description.contains("The specified pre-release build could not be added."))
        // The opaque JSON blob should not leak through once a detail is found.
        #expect(!description.contains("\"errors\""))
    }

    @Test("apiError description falls back to the raw body when it is not a JSON:API error")
    func apiErrorFallsBackToRawBody() {
        let error = ASCError.apiError(statusCode: 500, body: "upstream exploded")
        #expect(error.errorDescription == "App Store Connect API error (500): upstream exploded")
    }

    @Test("apiError description counts additional JSON:API errors")
    func apiErrorCountsAdditionalErrors() {
        let body = """
            {"errors":[{"title":"A","detail":"first problem"},{"title":"B","detail":"second problem"}]}
            """
        let error = ASCError.apiError(statusCode: 400, body: body)
        let description = error.errorDescription ?? ""
        #expect(description.contains("first problem"))
        #expect(description.contains("(+1 more)"))
    }

    @Test("jwtGenerationFailed description wraps the underlying error")
    func jwtErrorDescription() {
        let error = ASCError.jwtGenerationFailed(underlying: Underlying())
        #expect(error.errorDescription == "JWT generation failed: the underlying reason")
    }

    @Test("uploadFailed description names the asset and reason")
    func uploadFailedDescription() {
        let error = ASCError.uploadFailed(asset: "App.ipa", reason: "altool exited 1")
        #expect(error.errorDescription == "Upload failed for App.ipa: altool exited 1")
    }

    @Test("invalidConfiguration description includes the reason")
    func invalidConfigurationDescription() {
        let error = ASCError.invalidConfiguration(reason: "missing ASC_KEY_ID")
        #expect(error.errorDescription == "Invalid configuration: missing ASC_KEY_ID")
    }

    @Test("localizedDescription is wired through LocalizedError")
    func localizedDescriptionBridges() {
        let error = ASCError.invalidConfiguration(reason: "nope")
        #expect((error as any Error).localizedDescription == "Invalid configuration: nope")
    }
}
