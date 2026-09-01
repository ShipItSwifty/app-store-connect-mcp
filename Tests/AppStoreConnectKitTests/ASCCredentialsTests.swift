import Foundation
import Testing

@testable import AppStoreConnectKit

@Suite("ASCCredentials")
struct ASCCredentialsTests {
    @Test("Resolves from environment with raw PEM")
    func fromEnvironmentPEM() {
        let creds = ASCCredentials.fromEnvironment([
            "ASC_KEY_ID": "K123",
            "ASC_ISSUER_ID": "I456",
            "ASC_PRIVATE_KEY": "-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----",
        ])
        #expect(creds?.keyID == "K123")
        #expect(creds?.issuerID == "I456")
        #expect(creds?.privateKeyData.isEmpty == false)
    }

    @Test("Returns nil when a required value is missing")
    func fromEnvironmentMissing() {
        #expect(ASCCredentials.fromEnvironment(["ASC_KEY_ID": "K"]) == nil)
        #expect(ASCCredentials.fromEnvironment(["ASC_KEY_ID": "K", "ASC_ISSUER_ID": "I"]) == nil)
    }
}
