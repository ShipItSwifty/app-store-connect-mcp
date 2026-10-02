import Foundation

/// The Model Context Protocol uses string-based version identifiers
/// following the format YYYY-MM-DD, to indicate
/// the last date backwards incompatible changes were made.
///
/// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/
public enum Version {
    /// Modern revisions implemented by the server. The client still uses the legacy handshake.
    public static let modernSupported: Set<String> = ["2026-07-28"]

    /// Revisions implemented by the legacy client and handshake-based server.
    public static let legacySupported: Set<String> = [
        "2025-11-25",
        "2025-06-18",
        "2025-03-26",
        "2024-11-05",
    ]

    public static let supported = modernSupported.union(legacySupported)

    /// The latest protocol version supported by the server.
    public static let latest = supported.max()!

    /// Latest revision supported by the legacy initialization and client APIs.
    public static let latestLegacy = legacySupported.max()!

    /// Negotiates the protocol version based on the client's request and server's capabilities.
    /// - Parameter clientRequestedVersion: The protocol version requested by the client.
    /// - Returns: The negotiated protocol version. If the client's requested version is supported,
    ///            that version is returned. Otherwise, the latest legacy version is returned.
    static func negotiate(clientRequestedVersion: String) -> String {
        if legacySupported.contains(clientRequestedVersion) {
            return clientRequestedVersion
        }
        return latestLegacy
    }
}
