import Foundation

#if canImport(Compression)
import Compression
#else
import CZlib
#endif

// MARK: - Minimal ZIP reader
//
// Xcode Cloud exposes a build action's full log set as a single `LOG_BUNDLE`
// artifact — a ZIP that holds the `xcodebuild` output *and* the stdout/stderr of
// every custom CI script (`ci_post_clone.sh`, `ci_pre_xcodebuild.sh`,
// `ci_post_xcodebuild.sh`). The App Store Connect API has no per-script text
// artifact, so the only way to see *why* a script failed is to expand that ZIP.
//
// This is a deliberately small, dependency-free reader: central-directory walk +
// `Compression`-framework DEFLATE. It handles the store (0) and deflate (8)
// methods and enough of ZIP64 to cope with large bundles; anything else is
// surfaced as a skipped entry rather than an error.

/// A single file extracted from a ``ZipArchive``.
struct ZipEntry: Sendable {
    /// The entry's path within the archive (forward-slash separated).
    let path: String
    /// The decompressed bytes.
    let data: Data
}

/// A read-only view over a ZIP archive held entirely in memory.
struct ZipArchive: Sendable {
    /// Why an archive could not be read, or an individual entry could not be extracted.
    enum ZipError: Error, CustomStringConvertible {
        case notAZip
        case truncated
        case unsupported(String)

        var description: String {
            switch self {
            case .notAZip: return "data is not a ZIP archive (missing PK signature)"
            case .truncated: return "ZIP archive is truncated or its central directory is corrupt"
            case .unsupported(let why): return "unsupported ZIP feature: \(why)"
            }
        }
    }

    /// Caps to keep a pathological archive from exhausting memory.
    static let maxEntryBytes = 64 * 1024 * 1024
    private static let maxTotalBytes = 256 * 1024 * 1024

    private static let localHeaderSignature: UInt32 = 0x0403_4b50
    private static let centralHeaderSignature: UInt32 = 0x0201_4b50
    private static let eocdSignature: UInt32 = 0x0605_4b50

    /// `true` if `data` starts with a local-file-header signature (`PK\u{03}\u{04}`).
    static func looksLikeZip(_ data: Data) -> Bool {
        data.count >= 4 && data[data.startIndex] == 0x50 && data[data.startIndex + 1] == 0x4B
            && data[data.startIndex + 2] == 0x03 && data[data.startIndex + 3] == 0x04
    }

    /// Extracts every store/deflate entry from `data`.
    ///
    /// - Parameter data: The full archive bytes.
    /// - Parameter shouldExtract: Optional filter on the entry path; return `false` to
    ///   skip an entry without decompressing it.
    /// - Returns: The extracted entries plus human-readable notes for entries that
    ///   were skipped (unsupported compression, ZIP64 gaps, size caps).
    static func entries(
        in data: Data,
        where shouldExtract: (String) -> Bool = { _ in true }
    ) throws -> (entries: [ZipEntry], skipped: [String]) {
        guard looksLikeZip(data) else { throw ZipError.notAZip }
        let bytes = [UInt8](data)

        guard let eocd = findEOCD(in: bytes) else { throw ZipError.truncated }
        var cursor = eocd.centralDirectoryOffset
        var results: [ZipEntry] = []
        var skipped: [String] = []
        var totalExtracted = 0

        for _ in 0..<eocd.entryCount {
            guard cursor + 46 <= bytes.count,
                readU32(bytes, cursor) == centralHeaderSignature
            else { throw ZipError.truncated }

            let method = readU16(bytes, cursor + 10)
            var compressedSize = Int(readU32(bytes, cursor + 20))
            var uncompressedSize = Int(readU32(bytes, cursor + 24))
            let nameLength = Int(readU16(bytes, cursor + 28))
            let extraLength = Int(readU16(bytes, cursor + 30))
            let commentLength = Int(readU16(bytes, cursor + 32))
            var localOffset = Int(readU32(bytes, cursor + 42))

            let nameStart = cursor + 46
            guard nameStart + nameLength + extraLength + commentLength <= bytes.count else {
                throw ZipError.truncated
            }
            let name = String(decoding: bytes[nameStart..<nameStart + nameLength], as: UTF8.self)
            let extraStart = nameStart + nameLength

            // Patch in ZIP64 values for any field that was left at the 0xFFFFFFFF sentinel.
            applyZip64(
                bytes: bytes,
                extraRange: extraStart..<extraStart + extraLength,
                uncompressedSize: &uncompressedSize,
                compressedSize: &compressedSize,
                localOffset: &localOffset
            )

            let nextEntry = extraStart + extraLength + commentLength

            defer { cursor = nextEntry }

            let isDirectory = name.hasSuffix("/")
            if isDirectory { continue }
            guard shouldExtract(name) else { continue }

            if method != 0 && method != 8 {
                skipped.append("\(name): unsupported compression method \(method)")
                continue
            }
            if compressedSize < 0 || uncompressedSize < 0 || uncompressedSize > maxEntryBytes {
                skipped.append("\(name): entry too large or size unknown (\(uncompressedSize) bytes)")
                continue
            }
            if totalExtracted + uncompressedSize > maxTotalBytes {
                skipped.append("\(name): archive extraction size cap reached")
                continue
            }

            guard localOffset + 30 <= bytes.count,
                readU32(bytes, localOffset) == localHeaderSignature
            else {
                skipped.append("\(name): local header missing or misaligned")
                continue
            }
            let localNameLength = Int(readU16(bytes, localOffset + 26))
            let localExtraLength = Int(readU16(bytes, localOffset + 28))
            let dataStart = localOffset + 30 + localNameLength + localExtraLength
            guard dataStart + compressedSize <= bytes.count else {
                skipped.append("\(name): compressed payload runs past end of archive")
                continue
            }
            let payload = bytes[dataStart..<dataStart + compressedSize]

            let out: Data
            if method == 0 {
                out = Data(payload)
            } else if let inflated = inflate(Array(payload), hint: uncompressedSize) {
                out = inflated
            } else {
                skipped.append("\(name): DEFLATE stream could not be decoded")
                continue
            }
            totalExtracted += out.count
            results.append(ZipEntry(path: name, data: out))
        }

        return (results, skipped)
    }

    // MARK: - Central directory

    private struct EOCD {
        let entryCount: Int
        let centralDirectoryOffset: Int
    }

    private static func findEOCD(in bytes: [UInt8]) -> EOCD? {
        guard bytes.count >= 22 else { return nil }
        let minStart = max(0, bytes.count - 22 - 65_535)
        var index = bytes.count - 22
        while index >= minStart {
            if readU32(bytes, index) == eocdSignature {
                let count = Int(readU16(bytes, index + 10))
                let offset = Int(readU32(bytes, index + 16))
                // ZIP64: a 0xFFFF/0xFFFFFFFF sentinel points at the ZIP64 EOCD record.
                if count == 0xFFFF || offset == 0xFFFF_FFFF {
                    return findZip64EOCD(in: bytes, near: index)
                }
                guard offset <= bytes.count else { return nil }
                return EOCD(entryCount: count, centralDirectoryOffset: offset)
            }
            index -= 1
        }
        return nil
    }

    private static func findZip64EOCD(in bytes: [UInt8], near eocdIndex: Int) -> EOCD? {
        // The ZIP64 EOCD locator sits 20 bytes before the regular EOCD.
        let locatorIndex = eocdIndex - 20
        guard locatorIndex >= 0, readU32(bytes, locatorIndex) == 0x0706_4b50 else { return nil }
        let zip64Index = Int(readU64(bytes, locatorIndex + 8))
        guard zip64Index >= 0, zip64Index + 56 <= bytes.count,
            readU32(bytes, zip64Index) == 0x0606_4b50
        else { return nil }
        let count = Int(readU64(bytes, zip64Index + 32))
        let offset = Int(readU64(bytes, zip64Index + 48))
        guard offset >= 0, offset <= bytes.count else { return nil }
        return EOCD(entryCount: count, centralDirectoryOffset: offset)
    }

    private static func applyZip64(
        bytes: [UInt8],
        extraRange: Range<Int>,
        uncompressedSize: inout Int,
        compressedSize: inout Int,
        localOffset: inout Int
    ) {
        guard extraRange.lowerBound >= 0, extraRange.upperBound <= bytes.count else { return }
        var index = extraRange.lowerBound
        while index + 4 <= extraRange.upperBound {
            let headerID = readU16(bytes, index)
            let fieldSize = Int(readU16(bytes, index + 2))
            let fieldStart = index + 4
            guard fieldStart + fieldSize <= extraRange.upperBound else { return }
            if headerID == 0x0001 {
                var field = fieldStart
                if uncompressedSize == 0xFFFF_FFFF, field + 8 <= fieldStart + fieldSize {
                    uncompressedSize = Int(readU64(bytes, field))
                    field += 8
                }
                if compressedSize == 0xFFFF_FFFF, field + 8 <= fieldStart + fieldSize {
                    compressedSize = Int(readU64(bytes, field))
                    field += 8
                }
                if localOffset == 0xFFFF_FFFF, field + 8 <= fieldStart + fieldSize {
                    localOffset = Int(readU64(bytes, field))
                    field += 8
                }
                return
            }
            index = fieldStart + fieldSize
        }
    }

    // MARK: - DEFLATE

    /// Raw-DEFLATE decode. Package-internal so `Gzip` can reuse it: a gzip member is a
    /// raw DEFLATE stream between a header and an 8-byte trailer.
    static func inflate(_ input: [UInt8], hint: Int) -> Data? {
        guard !input.isEmpty else { return Data() }
        // An empty file still has a (tiny) DEFLATE stream, which decodes to zero
        // bytes. Without this, every empty log inside a bundle was reported as a
        // corrupt stream rather than as the empty file it is.
        if hint == 0 { return Data() }

        #if canImport(Compression)
        // A ZIP central-directory entry carries the exact uncompressed size, so when
        // `hint` is trustworthy do a single-shot decode. Only when it is unknown
        // (ZIP64 gaps, streamed entries) fall back to a doubling buffer.
        var capacity = hint > 0 ? hint : max(input.count * 4, 64 * 1024)

        while capacity <= maxEntryBytes {
            var output = [UInt8](repeating: 0, count: max(capacity, 1))
            let written = output.withUnsafeMutableBufferPointer { dst -> Int in
                guard let dstBase = dst.baseAddress else { return 0 }
                return input.withUnsafeBufferPointer { src -> Int in
                    guard let srcBase = src.baseAddress else { return 0 }
                    return compression_decode_buffer(
                        dstBase, dst.count, srcBase, src.count, nil, COMPRESSION_ZLIB)
                }
            }
            if written == 0 { return nil }
            if written == output.count && hint <= 0 {
                // Buffer filled exactly and we can't trust the size — grow and retry.
                capacity *= 2
                continue
            }
            return Data(output[0..<written])
        }
        return nil
        #else
        return zlibInflate(input, hint: hint)
        #endif
    }

    #if !canImport(Compression)
    /// Raw-DEFLATE decode via zlib (`windowBits: -15`), for platforms without `Compression`.
    private static func zlibInflate(_ input: [UInt8], hint: Int) -> Data? {
        var stream = z_stream()
        guard
            inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
        else { return nil }
        defer { inflateEnd(&stream) }

        var output: [UInt8] = []
        let chunkSize = hint > 0 ? hint : max(input.count * 4, 64 * 1024)

        let status: Int32? = input.withUnsafeBufferPointer { src -> Int32? in
            guard let srcBase = UnsafeMutablePointer(mutating: src.baseAddress) else { return nil }
            stream.next_in = srcBase
            stream.avail_in = UInt32(src.count)

            var status: Int32 = Z_OK
            repeat {
                if output.count + chunkSize > maxEntryBytes { return Z_BUF_ERROR }
                var buffer = [UInt8](repeating: 0, count: chunkSize)
                let written: Int = buffer.withUnsafeMutableBufferPointer { dst -> Int in
                    guard let dstBase = dst.baseAddress else { return -1 }
                    stream.next_out = dstBase
                    stream.avail_out = UInt32(dst.count)
                    status = CZlib.inflate(&stream, Z_NO_FLUSH)
                    return dst.count - Int(stream.avail_out)
                }
                if written < 0 { return nil }
                output.append(contentsOf: buffer[0..<written])
            } while status == Z_OK && stream.avail_out == 0
            return status
        }

        guard status == Z_STREAM_END || status == Z_OK else { return nil }
        return Data(output)
    }
    #endif

    // MARK: - Little-endian reads (all bounds-checked by the callers)

    private static func readU16(_ bytes: [UInt8], _ offset: Int) -> Int {
        Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
    }

    private static func readU32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8) | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func readU64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 { value |= UInt64(bytes[offset + i]) << (8 * i) }
        return value
    }
}
