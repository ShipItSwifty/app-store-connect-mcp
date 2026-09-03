import Foundation

/// Decodes a single gzip member (RFC 1952).
///
/// App Store Connect serves its bulk reports gzipped — sales and trends reports come
/// back as gzipped TSV, and an analytics report segment is a gzipped CSV behind a
/// signed URL. Neither is usable without inflating it first.
///
/// The gzip container is a header, a raw DEFLATE stream, and an 8-byte trailer, so
/// this parses the frame and hands the payload to ``ZipArchive/inflate(_:hint:)``
/// rather than carrying a second decompressor.
enum Gzip {
    /// Why a payload could not be decoded.
    enum GzipError: Error, CustomStringConvertible {
        case notGzip
        case truncated
        case unsupported(String)
        case corrupt
        /// The inflated bytes did not match the trailer's CRC32 or length.
        case checksumMismatch

        var description: String {
            switch self {
            case .notGzip: return "data is not gzip-compressed (missing 0x1f 0x8b magic)"
            case .truncated: return "gzip data is truncated"
            case .unsupported(let why): return "unsupported gzip feature: \(why)"
            case .corrupt: return "gzip stream could not be inflated"
            case .checksumMismatch: return "gzip contents failed their CRC32/length check"
            }
        }
    }

    /// `true` if `data` starts with the gzip magic bytes.
    static func looksLikeGzip(_ data: Data) -> Bool {
        data.count >= 2 && data[data.startIndex] == 0x1F && data[data.startIndex + 1] == 0x8B
    }

    /// Inflates a gzip member.
    ///
    /// - Throws: ``GzipError`` when the frame is malformed or uses a feature this
    ///   decoder does not implement.
    static func decompress(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        // 10-byte fixed header + 8-byte trailer is the smallest possible member.
        guard bytes.count >= 18 else { throw bytes.count >= 2 ? GzipError.truncated : GzipError.notGzip }
        guard bytes[0] == 0x1F, bytes[1] == 0x8B else { throw GzipError.notGzip }
        guard bytes[2] == 8 else { throw GzipError.unsupported("compression method \(bytes[2])") }

        let flags = bytes[3]
        var offset = 10

        if flags & 0x04 != 0 {  // FEXTRA
            guard offset + 2 <= bytes.count else { throw GzipError.truncated }
            let extraLength = Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
            offset += 2 + extraLength
        }
        for flag in [UInt8(0x08), UInt8(0x10)] where flags & flag != 0 {  // FNAME, FCOMMENT
            guard let end = bytes[offset...].firstIndex(of: 0) else { throw GzipError.truncated }
            offset = end + 1
        }
        if flags & 0x02 != 0 { offset += 2 }  // FHCRC

        guard offset < bytes.count - 8 else { throw GzipError.truncated }

        // ISIZE is the uncompressed length mod 2^32 — an exact hint for anything under
        // 4 GB, which every report this package downloads is.
        let sizeStart = bytes.count - 4
        let isize =
            UInt32(bytes[sizeStart]) | (UInt32(bytes[sizeStart + 1]) << 8)
            | (UInt32(bytes[sizeStart + 2]) << 16) | (UInt32(bytes[sizeStart + 3]) << 24)
        let hint = isize > 0 && Int(isize) <= ZipArchive.maxEntryBytes ? Int(isize) : 0

        let crcStart = bytes.count - 8
        let expectedCRC =
            UInt32(bytes[crcStart]) | (UInt32(bytes[crcStart + 1]) << 8)
            | (UInt32(bytes[crcStart + 2]) << 16) | (UInt32(bytes[crcStart + 3]) << 24)

        let deflated = Array(bytes[offset..<crcStart])
        guard let inflated = ZipArchive.inflate(deflated, hint: hint) else { throw GzipError.corrupt }

        // The trailer is the only thing that catches a stream that inflated to
        // *something*: a corrupt member decodes to a partial buffer rather than
        // failing, and silently handing back half a sales report would be worse than
        // an error.
        guard UInt32(truncatingIfNeeded: inflated.count) == isize, crc32(inflated) == expectedCRC else {
            throw GzipError.checksumMismatch
        }
        return inflated
    }

    /// CRC-32 (IEEE 802.3), computed with the standard reflected table.
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = (crc >> 8) ^ table[Int((crc ^ UInt32(byte)) & 0xFF)]
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1
        }
        return value
    }

    /// Inflates a gzip member and decodes it as UTF-8 text, which is what every
    /// App Store Connect report is.
    static func decompressText(_ data: Data) throws -> String {
        String(decoding: try decompress(data), as: UTF8.self)
    }
}
