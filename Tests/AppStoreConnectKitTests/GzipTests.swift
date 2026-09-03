import Foundation
import Testing

@testable import AppStoreConnectKit

/// Covers the gzip frame parser used for sales and analytics reports.
@Suite("Gzip")
struct GzipTests {
    /// Builds a gzip member with `gzip` itself, so the fixtures are real frames rather
    /// than something this decoder and its test agree on between themselves.
    private func gzipped(_ text: String, extraFlags: [String] = []) throws -> Data {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("report.tsv")
        try Data(text.utf8).write(to: source)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        // `-n` omits the name; without it gzip sets FNAME, which is the header field
        // most likely to be mis-parsed, so both forms are worth covering.
        process.arguments = ["gzip"] + extraFlags + ["-c", source.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }

    @Test("Round-trips a real gzip member, with and without a stored file name")
    func roundTrip() throws {
        let text = "Provider\tCountry\tUnits\nAPPLE\tUS\t42\n"
        for flags in [[], ["-n"]] {
            let data = try gzipped(text, extraFlags: flags)
            #expect(Gzip.looksLikeGzip(data))
            #expect(try Gzip.decompressText(data) == text)
        }
    }

    @Test("Handles a payload larger than one buffer")
    func largePayload() throws {
        let text = String(repeating: "row\tvalue\n", count: 50_000)
        #expect(try Gzip.decompressText(try gzipped(text)) == text)
    }

    @Test("Rejects data that is not a gzip member")
    func rejectsNonGzip() {
        #expect(!Gzip.looksLikeGzip(Data("plain text".utf8)))
        #expect(throws: Gzip.GzipError.self) { _ = try Gzip.decompress(Data("plain text, long enough".utf8)) }
        // Magic bytes but nothing after them: truncated, not "not gzip".
        #expect(throws: Gzip.GzipError.self) { _ = try Gzip.decompress(Data([0x1F, 0x8B])) }
        #expect(throws: Gzip.GzipError.self) { _ = try Gzip.decompress(Data()) }
    }

    @Test("CRC32 matches the known check value")
    func crcCheckValue() {
        // The IEEE 802.3 check value for "123456789", from the CRC catalogue.
        #expect(Gzip.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(Gzip.crc32(Data()) == 0)
    }

    @Test("Rejects a member whose deflate stream is corrupt")
    func rejectsCorruptStream() throws {
        // `-n` keeps the header at a fixed 10 bytes, so the corruption definitely lands
        // in the DEFLATE stream rather than in a stored file name.
        var bytes = [UInt8](try gzipped(String(repeating: "hello world\n", count: 200), extraFlags: ["-n"]))
        for index in 11..<20 { bytes[index] ^= 0xFF }
        // Corruption can inflate to *something*; only the trailer catches that.
        #expect(throws: Gzip.GzipError.self) { _ = try Gzip.decompress(Data(bytes)) }
    }
}
