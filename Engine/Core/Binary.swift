import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Compression) && !HANX_PORTABLE
import Compression
#else
import CMiniz
#endif

enum FormatError: Error, CustomStringConvertible {
    case invalid(String)
    case unsupported(String)

    var description: String {
        switch self {
        case .invalid(let m): return "잘못된 파일 형식: \(m)"
        case .unsupported(let m): return "지원하지 않는 기능: \(m)"
        }
    }
}

/// Little-endian cursor over a byte buffer. All reads are bounds-checked and
/// return zero instead of trapping, because real-world HWP records are often
/// shorter than the spec says (older writers omit trailing fields).
struct ByteReader {
    let data: [UInt8]
    var pos: Int

    init(_ data: [UInt8], at pos: Int = 0) { self.data = data; self.pos = pos }
    init(_ data: Data) { self.data = [UInt8](data); self.pos = 0 }

    var remaining: Int { max(0, data.count - pos) }
    var atEnd: Bool { pos >= data.count }

    mutating func skip(_ n: Int) { pos += n }

    mutating func u8() -> UInt8 {
        defer { pos += 1 }
        return pos < data.count ? data[pos] : 0
    }
    mutating func i8() -> Int8 { Int8(bitPattern: u8()) }
    mutating func u16() -> UInt16 {
        let a = UInt16(u8()), b = UInt16(u8())
        return a | (b << 8)
    }
    mutating func i16() -> Int16 { Int16(bitPattern: u16()) }
    mutating func u32() -> UInt32 {
        let a = UInt32(u16()), b = UInt32(u16())
        return a | (b << 16)
    }
    mutating func i32() -> Int32 { Int32(bitPattern: u32()) }
    mutating func u64() -> UInt64 {
        let a = UInt64(u32()), b = UInt64(u32())
        return a | (b << 32)
    }
    mutating func bytes(_ n: Int) -> [UInt8] {
        let start = min(pos, data.count), end = min(pos + max(0, n), data.count)
        pos += n
        return Array(data[start..<end])
    }
    /// UTF-16LE string of `count` code units.
    mutating func utf16(_ count: Int) -> String {
        var units = [UInt16]()
        units.reserveCapacity(count)
        for _ in 0..<max(0, count) { units.append(u16()) }
        return String(decoding: units, as: UTF16.self)
    }

    static func u16(_ d: [UInt8], _ o: Int) -> UInt16 {
        guard o + 1 < d.count else { return 0 }
        return UInt16(d[o]) | UInt16(d[o + 1]) << 8
    }
    static func u32(_ d: [UInt8], _ o: Int) -> UInt32 {
        guard o + 3 < d.count else { return 0 }
        return UInt32(d[o]) | UInt32(d[o + 1]) << 8 | UInt32(d[o + 2]) << 16 | UInt32(d[o + 3]) << 24
    }
}

struct ByteWriter {
    var data = [UInt8]()

    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func i8(_ v: Int8) { data.append(UInt8(bitPattern: v)) }
    mutating func u16(_ v: UInt16) { data.append(UInt8(v & 0xFF)); data.append(UInt8(v >> 8)) }
    mutating func i16(_ v: Int16) { u16(UInt16(bitPattern: v)) }
    mutating func u32(_ v: UInt32) { u16(UInt16(v & 0xFFFF)); u16(UInt16(v >> 16)) }
    mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
    mutating func u64(_ v: UInt64) { u32(UInt32(v & 0xFFFF_FFFF)); u32(UInt32(v >> 32)) }
    mutating func bytes(_ b: [UInt8]) { data.append(contentsOf: b) }
    mutating func zeros(_ n: Int) { data.append(contentsOf: [UInt8](repeating: 0, count: max(0, n))) }
    mutating func utf16(_ s: String) { for u in s.utf16 { u16(u) } }
    mutating func pad(to n: Int) { if data.count < n { zeros(n - data.count) } }
}

/// Raw DEFLATE (RFC 1951) via Apple's Compression framework. Both HWP streams
/// and ZIP entries use headerless deflate, which is what COMPRESSION_ZLIB is.
enum Deflate {
#if canImport(Compression) && !HANX_PORTABLE
    static func inflate(_ input: [UInt8]) throws -> [UInt8] {
        try run(input, operation: COMPRESSION_STREAM_DECODE)
    }

    static func deflate(_ input: [UInt8]) throws -> [UInt8] {
        try run(input, operation: COMPRESSION_STREAM_ENCODE)
    }

    private static func run(_ input: [UInt8], operation: compression_stream_operation) throws -> [UInt8] {
        if input.isEmpty && operation == COMPRESSION_STREAM_DECODE { return [] }
        let bufSize = 1 << 16
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { dst.deallocate() }
        var stream = compression_stream(dst_ptr: dst, dst_size: 0, src_ptr: UnsafePointer(dst), src_size: 0, state: nil)
        guard compression_stream_init(&stream, operation, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw FormatError.invalid("deflate 초기화 실패")
        }
        defer { compression_stream_destroy(&stream) }
        var output = [UInt8]()
        try input.withUnsafeBufferPointer { src in
            stream.src_ptr = src.baseAddress ?? UnsafePointer(dst)
            stream.src_size = src.count
            while true {
                stream.dst_ptr = dst
                stream.dst_size = bufSize
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                output.append(contentsOf: UnsafeBufferPointer(start: dst, count: bufSize - stream.dst_size))
                if status == COMPRESSION_STATUS_END { break }
                if status == COMPRESSION_STATUS_ERROR {
                    // Truncated streams still yield usable text; keep what decoded.
                    if operation == COMPRESSION_STREAM_DECODE && !output.isEmpty { break }
                    throw FormatError.invalid("deflate 데이터 손상")
                }
                if stream.src_size == 0 && stream.dst_size > 0 && operation == COMPRESSION_STREAM_DECODE { break }
            }
        }
        return output
    }
#else
    static func inflate(_ input: [UInt8]) throws -> [UInt8] { try run(input, decode: true) }
    static func deflate(_ input: [UInt8]) throws -> [UInt8] { try run(input, decode: false) }
    private static func run(_ input: [UInt8], decode: Bool) throws -> [UInt8] {
        if input.isEmpty && decode { return [] }
        var stream = mz_stream()
        let initialized = decode ? mz_inflateInit2(&stream, -15) : mz_deflateInit2(&stream, 6, 8, -15, 8, 0)
        guard initialized == MZ_OK else { throw FormatError.invalid("Cannot initialize DEFLATE") }
        defer { if decode { mz_inflateEnd(&stream) } else { mz_deflateEnd(&stream) } }
        var result = [UInt8]()
        try input.withUnsafeBufferPointer { src in
            stream.next_in = src.baseAddress
            stream.avail_in = UInt32(src.count)
            var chunk = [UInt8](repeating: 0, count: 65536)
            while true {
                let status = chunk.withUnsafeMutableBufferPointer { dst -> Int32 in
                    stream.next_out = dst.baseAddress
                    stream.avail_out = UInt32(dst.count)
                    return decode ? mz_inflate(&stream, Int32(MZ_FINISH)) : mz_deflate(&stream, Int32(MZ_FINISH))
                }
                let count = chunk.count - Int(stream.avail_out)
                result.append(contentsOf: chunk.prefix(count))
                guard result.count <= 512 * 1024 * 1024 else { throw FormatError.unsupported("DEFLATE stream exceeds 512 MiB") }
                if status == MZ_STREAM_END { break }
                guard (status == MZ_OK || status == MZ_BUF_ERROR), count > 0 else { throw FormatError.invalid("Corrupt DEFLATE stream") }
            }
        }
        return result
    }
#endif

}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}
