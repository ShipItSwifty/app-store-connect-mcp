import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Typed App Store Connect API credentials.
///
/// This is the type-safe seam that replaces passing an ad-hoc configuration bag
/// (or a host application's context) into the client and its services.
public struct ASCCredentials: Sendable {
    /// The API Key ID from App Store Connect (Users and Access → Integrations → App Store Connect API).
    public let keyID: String

    /// The Issuer ID from App Store Connect.
    public let issuerID: String

    /// Raw contents of the `.p8` private key file.
    public let privateKeyData: Data

    /// Creates ``ASCCredentials``.
    public init(keyID: String, issuerID: String, privateKeyData: Data) {
        self.keyID = keyID
        self.issuerID = issuerID
        self.privateKeyData = privateKeyData
    }

    /// Creates ``ASCCredentials`` from the raw PEM text of a `.p8` key.
    public init(keyID: String, issuerID: String, privateKeyPEM: String) {
        self.init(keyID: keyID, issuerID: issuerID, privateKeyData: Data(privateKeyPEM.utf8))
    }

    /// Resolves credentials from the conventional environment variables:
    /// `ASC_KEY_ID`, `ASC_ISSUER_ID`, and either `ASC_PRIVATE_KEY` (raw PEM) or
    /// `ASC_PRIVATE_KEY_PATH` (path to the `.p8` file).
    ///
    /// - Returns: `nil` if any required value is missing or the key file cannot be read.
    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ASCCredentials? {
        guard
            let keyID = environment["ASC_KEY_ID"], !keyID.isEmpty,
            let issuerID = environment["ASC_ISSUER_ID"], !issuerID.isEmpty
        else { return nil }

        if let pem = environment["ASC_PRIVATE_KEY"], !pem.isEmpty {
            return ASCCredentials(keyID: keyID, issuerID: issuerID, privateKeyData: Data(pem.utf8))
        }
        if let path = environment["ASC_PRIVATE_KEY_PATH"], !path.isEmpty,
            let data = try? Data(contentsOf: URL(fileURLWithPath: path))
        {
            return ASCCredentials(keyID: keyID, issuerID: issuerID, privateKeyData: data)
        }
        return nil
    }
}

extension AppStoreConnectClient {
    /// Creates a client from typed ``ASCCredentials``.
    ///
    /// - Parameters:
    ///   - credentials: The API key credentials.
    ///   - serverURL: Optional proxy base URL. Defaults to Apple's API host.
    ///   - session: URL session used for outbound HTTP requests.
    public init(
        credentials: ASCCredentials,
        serverURL: URL? = nil,
        session: URLSession = .shared
    ) {
        self.init(
            keyID: credentials.keyID,
            issuerID: credentials.issuerID,
            privateKeyData: credentials.privateKeyData,
            serverURL: serverURL,
            session: session
        )
    }
}
