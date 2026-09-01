import Crypto
import Foundation
import Testing

@testable import AppStoreConnectKit

@Suite("AssetUploader", .serialized)
struct AssetUploaderTests {
    private func makeTempFile(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ascmcp-upload-\(UUID().uuidString).bin")
        try Data(bytes).write(to: url)
        return url
    }

    private func expectedMD5(_ bytes: [UInt8]) -> String {
        Insecure.MD5.hash(data: Data(bytes)).map { String(format: "%02hhx", $0) }.joined()
    }

    @Test("Uploads every part, reports progress, and returns the file's MD5")
    func happyPath() async throws {
        let bytes = Array(UInt8(0)..<UInt8(200))
        let fileURL = try makeTempFile(bytes)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let seenLengths = LockedBox<[Int]>([])
        let session = makeMockSession { request in
            seenLengths.mutate { $0.append(Int(request.value(forHTTPHeaderField: "Content-Length") ?? "-1") ?? -1) }
            #expect(request.httpMethod == "PUT")
            return .response(statusCode: 200, headers: [:], body: Data())
        }

        let reservation = UploadReservation(
            id: "res-1",
            operations: [
                UploadOperation(method: "PUT", url: "https://s3.example/part1", offset: 0, length: 128),
                UploadOperation(method: "PUT", url: "https://s3.example/part2", offset: 128, length: 72),
            ]
        )

        let progressValues = LockedBox<[Double]>([])
        let uploader = AssetUploader(session: session, retryPolicy: RetryPolicy(maxAttempts: 1, initialDelay: .zero))
        let commit = try await uploader.upload(fileURL: fileURL, to: reservation) { value in
            progressValues.mutate { $0.append(value) }
        }

        #expect(commit.id == "res-1")
        #expect(commit.uploaded == true)
        #expect(commit.checksum == expectedMD5(bytes))
        #expect(seenLengths.value == [128, 72])
        #expect(progressValues.value == [0.5, 1.0])
    }

    @Test("A non-2xx part response throws uploadFailed after retries are exhausted")
    func partFailure() async throws {
        let bytes = [UInt8](repeating: 7, count: 64)
        let fileURL = try makeTempFile(bytes)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let session = makeMockSession { _ in .response(statusCode: 500, headers: [:], body: Data("nope".utf8)) }
        let reservation = UploadReservation(
            id: "res-2",
            operations: [UploadOperation(method: "PUT", url: "https://s3.example/part1", offset: 0, length: 64)]
        )

        let uploader = AssetUploader(session: session, retryPolicy: RetryPolicy(maxAttempts: 2, initialDelay: .zero))
        await #expect(throws: ASCError.self) {
            _ = try await uploader.upload(fileURL: fileURL, to: reservation)
        }
    }

    @Test("An invalid operation URL throws uploadFailed")
    func invalidURL() async throws {
        let fileURL = try makeTempFile([1, 2, 3, 4])
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let session = makeMockSession { _ in .response(statusCode: 200, headers: [:], body: Data()) }
        let reservation = UploadReservation(
            id: "res-3",
            operations: [UploadOperation(method: "PUT", url: "", offset: 0, length: 4)]
        )
        let uploader = AssetUploader(session: session, retryPolicy: RetryPolicy(maxAttempts: 1, initialDelay: .zero))
        await #expect(throws: ASCError.self) {
            _ = try await uploader.upload(fileURL: fileURL, to: reservation)
        }
    }

    @Test("A missing file throws before any upload")
    func missingFile() async {
        let session = makeMockSession { _ in .response(statusCode: 200, headers: [:], body: Data()) }
        let reservation = UploadReservation(id: "res-4", operations: [])
        let uploader = AssetUploader(session: session)
        await #expect(throws: ASCError.self) {
            _ = try await uploader.upload(
                fileURL: URL(fileURLWithPath: "/no/such/file.bin"),
                to: reservation
            )
        }
    }
}
