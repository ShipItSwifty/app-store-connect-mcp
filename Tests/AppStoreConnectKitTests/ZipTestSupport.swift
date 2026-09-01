import Foundation
import Testing

/// Builds a real ZIP with `/usr/bin/zip` (present on macOS runners; installed via
/// apt on the Linux CI container) so tests exercise `ZipArchive` against genuine
/// DEFLATE streams and central-directory layout rather than a hand-rolled fixture.
func makeTestZip(_ files: [String: String]) throws -> Data {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ziptest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    for (name, contents) in files {
        let fileURL = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    let zipURL = dir.appendingPathComponent("bundle.zip")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    process.arguments = ["-q", "-r", zipURL.path, "."]
    process.currentDirectoryURL = dir
    try process.run()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0, "zip exited \(process.terminationStatus)")
    return try Data(contentsOf: zipURL)
}
