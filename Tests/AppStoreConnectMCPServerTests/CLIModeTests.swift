import Testing

@testable import AppStoreConnectMCPServer

@Suite("CLIMode")
struct CLIModeTests {
    @Test(
        "Recognised flags map to version/help, everything else serves",
        arguments: [
            (["app-store-connect-mcp"], CLIMode.serve),
            (["app-store-connect-mcp", "--version"], .version),
            (["app-store-connect-mcp", "-v"], .version),
            (["app-store-connect-mcp", "--help"], .help),
            (["app-store-connect-mcp", "-h"], .help),
            (["app-store-connect-mcp", "serve"], .serve),
            (["app-store-connect-mcp", "--unknown"], .serve),
            (["app-store-connect-mcp", "--version", "--help"], .version),
        ] as [([String], CLIMode)]
    )
    func mapsArguments(arguments: [String], expected: CLIMode) {
        #expect(CLIMode(arguments: arguments) == expected)
    }

    @Test("An empty argument vector serves rather than trapping")
    func emptyArgumentsServe() {
        #expect(CLIMode(arguments: []) == .serve)
    }
}
