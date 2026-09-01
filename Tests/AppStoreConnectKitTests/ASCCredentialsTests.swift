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

    @Test("Resolves from environment via ASC_PRIVATE_KEY_PATH")
    func fromEnvironmentKeyPath() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("k-\(UUID().uuidString).p8")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try "-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----".write(to: tmp, atomically: true, encoding: .utf8)

        let creds = ASCCredentials.fromEnvironment([
            "ASC_KEY_ID": "K", "ASC_ISSUER_ID": "I", "ASC_PRIVATE_KEY_PATH": tmp.path,
        ])
        #expect(creds?.privateKeyData.isEmpty == false)
    }

    @Test("Returns nil when the key path does not exist")
    func fromEnvironmentBadKeyPath() {
        let creds = ASCCredentials.fromEnvironment([
            "ASC_KEY_ID": "K", "ASC_ISSUER_ID": "I", "ASC_PRIVATE_KEY_PATH": "/no/such/key.p8",
        ])
        #expect(creds == nil)
    }

    @Test("privateKeyPEM initializer stores UTF-8 bytes")
    func pemInitializer() {
        let creds = ASCCredentials(keyID: "K", issuerID: "I", privateKeyPEM: "pem-text")
        #expect(creds.privateKeyData == Data("pem-text".utf8))
    }

    @Test("AppStoreConnectClient(credentials:) initializer runs, including the proxy overload")
    func clientFromCredentials() {
        let creds = ASCCredentials(keyID: "K", issuerID: "I", privateKeyData: Data("x".utf8))
        _ = AppStoreConnectClient(credentials: creds)
        _ = AppStoreConnectClient(credentials: creds, serverURL: URL(string: "https://proxy.example"))
    }
}
