import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// ZIP container used by both OOXML (OPC package) and HWPX (OWPML package).
final class ZipReader {
    struct Entry { let name: String; let method: UInt16; let compSize: Int; let size: Int; let localOffset: Int }

    private let bytes: [UInt8]
    private(set) var entries: [String: Entry] = [:]
    private(set) var order: [String] = []

    static func isZip(_ data: Data) -> Bool { data.count >= 4 && [UInt8](data.prefix(4)) == [0x50, 0x4B, 0x03, 0x04] }

    init(data: Data) throws {
        bytes = [UInt8](data)
        guard bytes.count >= 22 else { throw FormatError.invalid("ZIP 너무 작음") }
        var eocd = -1
        var i = bytes.count - 22
        let lowest = max(0, bytes.count - 22 - 65_535)
        while i >= lowest {
            if bytes[i] == 0x50 && bytes[i + 1] == 0x4B && bytes[i + 2] == 0x05 && bytes[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw FormatError.invalid("ZIP 중앙 디렉터리 없음") }
        let count = Int(ByteReader.u16(bytes, eocd + 10))
        var p = Int(ByteReader.u32(bytes, eocd + 16))
        for _ in 0..<count {
            guard ByteReader.u32(bytes, p) == 0x0201_4B50 else { break }
            let method = ByteReader.u16(bytes, p + 10)
            let comp = Int(ByteReader.u32(bytes, p + 20))
            let size = Int(ByteReader.u32(bytes, p + 24))
            let nlen = Int(ByteReader.u16(bytes, p + 28))
            let elen = Int(ByteReader.u16(bytes, p + 30))
            let clen = Int(ByteReader.u16(bytes, p + 32))
            let local = Int(ByteReader.u32(bytes, p + 42))
            let nameBytes = Array(bytes[min(p + 46, bytes.count)..<min(p + 46 + nlen, bytes.count)])
            // Office and Hancom both write UTF-8 names; fall back to lossy decoding.
            let name = String(bytes: nameBytes, encoding: .utf8) ?? String(decoding: nameBytes, as: UTF8.self)
            entries[name] = Entry(name: name, method: method, compSize: comp, size: size, localOffset: local)
            order.append(name)
            p += 46 + nlen + elen + clen
        }
    }

    func has(_ name: String) -> Bool { entries[name] != nil }

    /// Case-insensitive lookup; OPC part names are case-insensitive.
    func resolve(_ name: String) -> String? {
        let n = name.hasPrefix("/") ? String(name.dropFirst()) : name
        if entries[n] != nil { return n }
        let low = n.lowercased()
        return order.first { $0.lowercased() == low }
    }

    func read(_ name: String) -> Data? {
        guard let key = resolve(name), let e = entries[key] else { return nil }
        let p = e.localOffset
        guard ByteReader.u32(bytes, p) == 0x0403_4B50 else { return nil }
        let start = p + 30 + Int(ByteReader.u16(bytes, p + 26)) + Int(ByteReader.u16(bytes, p + 28))
        guard start <= bytes.count else { return nil }
        let raw = Array(bytes[start..<min(start + e.compSize, bytes.count)])
        switch e.method {
        case 0: return Data(raw)
        case 8: return (try? Deflate.inflate(raw)).map { Data($0) }
        default: return nil
        }
    }

    private static let textWhitespacePattern = #"<((?:[A-Za-z_][A-Za-z0-9_.-]*:)?t)\b([^<>]*)>([ \t\r\n]+)</\1\s*>"#
    private var officeTextWhitespace: NSRegularExpression? { Self.textWhitespaceRegex }
    private static let textWhitespaceRegex = try? NSRegularExpression(pattern: textWhitespacePattern)
    private static let protectedXMLRegex = try? NSRegularExpression(pattern: #"<!\[CDATA\[[\s\S]*?\]\]>|<!--[\s\S]*?-->|<\?[\s\S]*?\?>"#)

    func xml(_ name: String) -> XMLDocument? {
        guard let d = read(name) else { return nil }
        // Foundation on macOS can drop whitespace-only text even with
        // nodePreserveWhitespace and xml:space=preserve. Office <*:t> nodes
        // are semantic text runs; CDATA retains their literal spaces/tabs.
        var source = d
        if let xml = String(data: d, encoding: .utf8), let regex = officeTextWhitespace {
            let full = NSRange(xml.startIndex..., in: xml)
            let protected = Self.protectedXMLRegex?.matches(in: xml, range: full).map(\.range) ?? []
            let result = NSMutableString(string: xml)
            for match in regex.matches(in: xml, range: full).reversed() {
                guard !protected.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
                let replacement = regex.replacementString(for: match, in: xml, offset: 0,
                    template: "<$1$2><![CDATA[$3]]></$1>")
                result.replaceCharacters(in: match.range, with: replacement)
            }
            source = Data((result as String).utf8)
        }
        return try? XMLDocument(data: source, options: [.nodePreserveWhitespace, .nodePreserveCDATA])
    }
}

final class ZipWriter {
    private var out = [UInt8]()
    private var central = ByteWriter()
    private var count = 0

    func add(_ name: String, _ data: Data, compress: Bool = true) {
        let raw = [UInt8](data)
        let crc = CRC32.checksum(raw)
        var payload = raw
        var method: UInt16 = 0
        if compress && raw.count > 64, let c = try? Deflate.deflate(raw), c.count < raw.count {
            payload = c; method = 8
        }
        let nameBytes = Array(name.utf8)
        let offset = out.count
        var h = ByteWriter()
        h.u32(0x0403_4B50); h.u16(20); h.u16(0x800); h.u16(method)
        h.u16(0); h.u16(0x21)   // 1980-01-01 00:00
        h.u32(crc); h.u32(UInt32(payload.count)); h.u32(UInt32(raw.count))
        h.u16(UInt16(nameBytes.count)); h.u16(0)
        h.bytes(nameBytes)
        out.append(contentsOf: h.data)
        out.append(contentsOf: payload)

        central.u32(0x0201_4B50); central.u16(20); central.u16(20); central.u16(0x800); central.u16(method)
        central.u16(0); central.u16(0x21)
        central.u32(crc); central.u32(UInt32(payload.count)); central.u32(UInt32(raw.count))
        central.u16(UInt16(nameBytes.count)); central.u16(0); central.u16(0); central.u16(0); central.u16(0)
        central.u32(0); central.u32(UInt32(offset))
        central.bytes(nameBytes)
        count += 1
    }

    func add(_ name: String, _ text: String, compress: Bool = true) { add(name, Data(text.utf8), compress: compress) }

    func finish() -> Data {
        let cdOffset = out.count
        var result = out
        result.append(contentsOf: central.data)
        var e = ByteWriter()
        e.u32(0x0605_4B50); e.u16(0); e.u16(0)
        e.u16(UInt16(count)); e.u16(UInt16(count))
        e.u32(UInt32(central.data.count)); e.u32(UInt32(cdOffset)); e.u16(0)
        result.append(contentsOf: e.data)
        return Data(result)
    }
}

// MARK: - XML helpers shared by the OOXML and OWPML importers.

extension XMLNode {
    /// Local name without namespace prefix ("w:p" → "p").
    var local: String {
        if let l = localName, !l.isEmpty { return l }
        let n = name ?? ""
        if let i = n.firstIndex(of: ":") { return String(n[n.index(after: i)...]) }
        return n
    }
}

extension XMLElement {
    var elementChildren: [XMLElement] { (children ?? []).compactMap { $0 as? XMLElement } }

    func child(_ local: String) -> XMLElement? { elementChildren.first { $0.local == local } }
    func children(_ local: String) -> [XMLElement] { elementChildren.filter { $0.local == local } }

    /// Depth-first search for the first descendant with this local name.
    func first(_ local: String) -> XMLElement? {
        for c in elementChildren {
            if c.local == local { return c }
            if let f = c.first(local) { return f }
        }
        return nil
    }

    func all(_ local: String) -> [XMLElement] {
        var out: [XMLElement] = []
        for c in elementChildren {
            if c.local == local { out.append(c) }
            out.append(contentsOf: c.all(local))
        }
        return out
    }

    /// Attribute by local name, ignoring prefix.
    func attr(_ local: String) -> String? {
        for a in attributes ?? [] where a.local == local { return a.stringValue }
        return nil
    }
    /// Relationship-namespace attribute (r:id, r:embed), distinct from a plain `id`.
    func relAttr(_ local: String) -> String? {
        for a in attributes ?? [] where a.local == local && (a.name ?? "").contains(":") { return a.stringValue }
        return attr(local)
    }
    func attrDouble(_ local: String) -> Double? { attr(local).flatMap { Double($0) } }
    func attrInt(_ local: String) -> Int? { attr(local).flatMap { Int($0) } }
}

enum XMLEscape {
    static func text(_ s: String) -> String {
        var o = ""
        o.reserveCapacity(s.count)
        for ch in s.unicodeScalars {
            switch ch {
            case "&": o += "&amp;"
            case "<": o += "&lt;"
            case ">": o += "&gt;"
            case "\"": o += "&quot;"
            default:
                // XML 1.0 forbids most C0 controls.
                if ch.value < 0x20 && ch != "\t" && ch != "\n" && ch != "\r" { continue }
                if ch.value == 0xFFFE || ch.value == 0xFFFF { continue }
                o.unicodeScalars.append(ch)
            }
        }
        return o
    }
}
