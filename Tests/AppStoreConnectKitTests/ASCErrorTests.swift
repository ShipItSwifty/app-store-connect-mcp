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
