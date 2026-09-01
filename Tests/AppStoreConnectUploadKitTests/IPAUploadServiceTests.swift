#if os(macOS)
import Foundation
import SwiftyShell
import Testing

@testable import AppStoreConnectKit
@testable import AppStoreConnectUploadKit

@Suite("IPAUploadService", .serialized)
struct IPAUploadServiceTests {
    private func makeTempIPA() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ascmcp-\(UUID().uuidString).ipa")
        try Data("not a real ipa".utf8).write(to: url)
        return url
    }

    private let credentials = ASCCredentials(
        keyID: "KEY",
        issuerID: "ISSUER",
        privateKeyData: Data("placeholder".utf8)
    )

    private func client() -> AppStoreConnectClient {
        AppStoreConnectClient(
            keyID: "KEY",
            issuerID: "ISSUER",
            privateKeyData: Data("placeholder".utf8),
            tokenProvider: { "test-token" }
        )
    }

    @Test("missing IPA throws uploadFailed")
    func missingIPA() async throws {
        let shell = ShellContext(executor: MockExecutor { _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) })
        await #expect(throws: ASCError.self) {
            _ = try await IPAUploadService(client: client()).uploadIPA(
                at: URL(fileURLWithPath: "/no/such/App.ipa"),
                bundleID: "com.example.app",
                credentials: credentials,
                shell: shell
            )
        }
    }

    @Test("altool non-zero exit throws uploadFailed")
    func altoolFailure() async throws {
        let ipa = try makeTempIPA()
        defer { try? FileManager.default.removeItem(at: ipa) }

        let shell = ShellContext(
            executor: MockExecutor { command, _ in
                if command.description.contains("altool") {
                    throw ShellError.exitFailure(
                        command: command.description,
                        output: ShellOutput(stdout: "", stderr: "auth failure", exitCode: 1)
                    )
                }
                return ShellOutput(stdout: "", stderr: "", exitCode: 0)
            }
        )

        await #expect(throws: ASCError.self) {
            _ = try await IPAUploadService(client: client()).uploadIPA(
                at: ipa,
                bundleID: "com.example.app",
                credentials: credentials,
                shell: shell
            )
        }
    }

    @Test("altool success with resolveBuildID false returns a result")
    func altoolSuccessNoResolve() async throws {
        let ipa = try makeTempIPA()
        defer { try? FileManager.default.removeItem(at: ipa) }

        let shell = ShellContext(executor: MockExecutor { _, _ in ShellOutput(stdout: "{}", stderr: "", exitCode: 0) })

        let result = try await IPAUploadService(client: client()).uploadIPA(
            at: ipa,
            bundleID: "com.example.app",
            credentials: credentials,
            shell: shell,
            resolveBuildID: false
        )
        #expect(result.fileName == ipa.lastPathComponent)
        #expect(result.buildID == nil)
    }
}
#endif
