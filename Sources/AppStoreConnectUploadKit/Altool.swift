#if os(macOS)
import Foundation
import SwiftyShell

/// A minimal typed wrapper for `xcrun altool` upload commands.
struct Altool: Sendable {
    private let shell: ShellContext
    private let arguments: [String]

    init(context: ShellContext) {
        self.shell = context
        self.arguments = []
    }

    private init(shell: ShellContext, arguments: [String]) {
        self.shell = shell
        self.arguments = arguments
    }

    /// Configures `altool --upload-app` with App Store Connect API key authentication.
    func uploadApp(ipaPath: String, platform: String, apiKey: String, apiIssuer: String) -> Altool {
        Altool(
            shell: shell,
            arguments: [
                "altool",
                "--upload-app",
                "-f", ipaPath,
                "-t", platform,
                "--apiKey", apiKey,
                "--apiIssuer", apiIssuer,
                "--output-format", "json",
            ]
        )
    }

    /// Runs the configured `xcrun altool` command.
    @discardableResult
    func run() async throws -> ShellOutput {
        try await Command("xcrun").args(arguments).run(in: shell)
    }
}
#endif
