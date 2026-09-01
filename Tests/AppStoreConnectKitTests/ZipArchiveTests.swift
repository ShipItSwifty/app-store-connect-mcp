import Foundation
import Testing

@testable import AppStoreConnectKit

@Suite("ZipArchive")
struct ZipArchiveTests {
    private func makeZip(_ files: [String: String]) throws -> Data { try makeTestZip(files) }

    @Test("looksLikeZip recognises the PK\\x03\\x04 signature")
    func detectsSignature() {
        #expect(ZipArchive.looksLikeZip(Data([0x50, 0x4B, 0x03, 0x04, 0x00])))
        #expect(!ZipArchive.looksLikeZip(Data("plain text log".utf8)))
        #expect(!ZipArchive.looksLikeZip(Data()))
    }

    @Test("An empty file extracts as empty rather than being skipped as corrupt")
    func emptyEntryExtracts() throws {
        let zip = try makeZip([
            "ci_post_xcodebuild.log": "",
            "xcodebuild.log": "all good\n",
        ])
        let (entries, skipped) = try ZipArchive.entries(in: zip)
        let empty = try #require(entries.first { $0.path.hasSuffix("ci_post_xcodebuild.log") })
        #expect(empty.data.isEmpty)
        #expect(!skipped.contains { $0.contains("ci_post_xcodebuild.log") })
    }

    @Test("entries decompresses every file and preserves paths")
    func extractsEntries() throws {
        let zip = try makeZip([
            "xcodebuild.log": String(repeating: "Sources/A.swift:1:1: warning: x\n", count: 400),
            "scripts/ci_post_xcodebuild.sh.log": "+ swiftlint\nerror: script phase failed\n",
        ])
        let (entries, skipped) = try ZipArchive.entries(in: zip)
        let byPath = Dictionary(
            uniqueKeysWithValues: entries.map { ($0.path, String(decoding: $0.data, as: UTF8.self)) })

        #expect(byPath["xcodebuild.log"]?.contains("warning: x") == true)
        #expect(byPath["scripts/ci_post_xcodebuild.sh.log"]?.contains("script phase failed") == true)
        #expect(!entries.contains { $0.path.hasSuffix("/") }, "directory entries must be skipped")
        #expect(skipped.isEmpty)
    }

    @Test("entries applies the path filter without decompressing skipped files")
    func honoursFilter() throws {
        let zip = try makeZip([
            "keep.log": "error: boom\n",
            "drop.bin": "ignored\n",
        ])
        let (entries, _) = try ZipArchive.entries(in: zip) { $0.hasSuffix(".log") }
        #expect(entries.map(\.path) == ["keep.log"])
    }

    @Test("entries throws notAZip for non-archive data")
    func rejectsNonZip() {
        #expect(throws: ZipArchive.ZipError.self) {
            _ = try ZipArchive.entries(in: Data("not a zip".utf8))
        }
    }

    @Test("entries throws truncated when the central directory is unreadable")
    func rejectsTruncated() throws {
        var zip = try makeZip(["a.log": "hello\n", "b.log": "world\n"])
        // Keep the PK\x03\x04 local header but lop off the central directory + EOCD.
        zip = zip.prefix(12)
        #expect(throws: ZipArchive.ZipError.self) {
            _ = try ZipArchive.entries(in: zip)
        }
    }

    @Test("large deflate payloads round-trip (single-shot decode using the size hint)")
    func largePayloadRoundTrips() throws {
        let big = String(repeating: "warning: something is off at line 1\n", count: 5_000)
        let zip = try makeZip(["huge.log": big])
        let (entries, _) = try ZipArchive.entries(in: zip)
        let recovered = try #require(entries.first { $0.path == "huge.log" })
        #expect(String(decoding: recovered.data, as: UTF8.self) == big)
    }
}
