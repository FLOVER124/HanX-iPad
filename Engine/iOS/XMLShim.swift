import Foundation

// iPadOS Foundation has no XMLDocument/XMLElement (they exist only on macOS
// and, through FoundationXML, on Linux/Windows). The shared engine reads
// OOXML/OWPML with that small DOM subset, so this file supplies a compatible
// tree built by a strict-enough, non-validating UTF-8 parser.
//
// Security: DOCTYPE declarations are skipped, never expanded, so documents
// cannot define entities (no billion-laughs, no external entity access).
#if os(iOS) || os(visionOS) || os(tvOS) || os(watchOS) || HANX_XML_SHIM

class XMLNode {
    enum Kind { case invalid, document, element, attribute, namespace, processingInstruction, comment, text }

    struct Options: OptionSet {
        let rawValue: UInt
        init(rawValue: UInt) { self.rawValue = rawValue }
        static let nodePreserveWhitespace = Options(rawValue: 1 << 0)
        static let nodePreserveCDATA = Options(rawValue: 1 << 1)
        static let nodeLoadExternalEntitiesNever = Options(rawValue: 1 << 2)
    }

    let kind: Kind
    var name: String?
    fileprivate var storedValue: String?
    fileprivate(set) var children: [XMLNode]?
    fileprivate(set) weak var parent: XMLNode?

    init(kind: Kind, name: String? = nil, value: String? = nil) {
        self.kind = kind
        self.name = name
        self.storedValue = value
    }

    var localName: String? {
        guard let name else { return nil }
        if let i = name.firstIndex(of: ":") { return String(name[name.index(after: i)...]) }
        return name
    }

    var prefix: String? {
        guard let name, let i = name.firstIndex(of: ":") else { return name == nil ? nil : "" }
        return String(name[..<i])
    }

    /// Text and attribute nodes return their own value; elements and documents
    /// return the concatenated text of every descendant, like Foundation.
    var stringValue: String? {
        switch kind {
        case .text, .attribute, .comment, .processingInstruction, .namespace: return storedValue
        default:
            var out = ""
            func walk(_ node: XMLNode) {
                for child in node.children ?? [] {
                    if child.kind == .text { out += child.storedValue ?? "" }
                    else if child.kind == .element { walk(child) }
                }
            }
            walk(self)
            return out
        }
    }

    var childCount: Int { children?.count ?? 0 }
    func child(at index: Int) -> XMLNode? {
        guard let children, children.indices.contains(index) else { return nil }
        return children[index]
    }
    var index: Int { parent?.children?.firstIndex { $0 === self } ?? 0 }

    fileprivate func append(_ node: XMLNode) {
        node.parent = self
        if children == nil { children = [] }
        children!.append(node)
    }

    // MARK: Minimal XPath (FILTERXML): /a/b, //a, //a/b, *, @attr, text()

    func nodes(forXPath xpath: String) throws -> [XMLNode] {
        var path = Substring(xpath.trimmingCharacters(in: .whitespaces))
        guard !path.isEmpty else { throw XMLShimError.xpath }
        var current: [XMLNode]
        if path.hasPrefix("/") {
            var top: XMLNode = self
            while let p = top.parent { top = p }
            current = [top]
        } else {
            current = [self]
        }
        while !path.isEmpty {
            var descendant = false
            if path.hasPrefix("//") { descendant = true; path = path.dropFirst(2) }
            else if path.hasPrefix("/") { path = path.dropFirst() }
            let end = path.firstIndex(of: "/") ?? path.endIndex
            let step = String(path[..<end])
            path = path[end...]
            guard !step.isEmpty else { throw XMLShimError.xpath }
            var next: [XMLNode] = []
            for node in current {
                let pool: [XMLNode] = descendant ? node.descendants(includingSelf: true) : [node]
                for candidate in pool {
                    if step == "." { next.append(candidate); continue }
                    if step == ".." { if let p = candidate.parent { next.append(p) }; continue }
                    if step == "text()" {
                        next += (candidate.children ?? []).filter { $0.kind == .text }
                        continue
                    }
                    if step.hasPrefix("@") {
                        let attr = String(step.dropFirst())
                        if let element = candidate as? XMLElement {
                            next += (element.attributes ?? []).filter { attr == "*" || $0.name == attr || $0.localName == attr }
                        }
                        continue
                    }
                    let (stepName, predicate) = XMLNode.splitPredicate(step)
                    var matches = (candidate.children ?? []).filter {
                        $0.kind == .element && (stepName == "*" || $0.name == stepName || $0.localName == stepName)
                    }
                    if let predicate {
                        guard let position = Int(predicate), position >= 1 else { throw XMLShimError.xpath }
                        matches = matches.indices.contains(position - 1) ? [matches[position - 1]] : []
                    }
                    next += matches
                }
            }
            var seen = Set<ObjectIdentifier>()
            current = next.filter { seen.insert(ObjectIdentifier($0)).inserted }
        }
        return current
    }

    private static func splitPredicate(_ step: String) -> (String, String?) {
        guard let open = step.firstIndex(of: "["), step.hasSuffix("]") else { return (step, nil) }
        let name = String(step[..<open])
        let inner = step[step.index(after: open)..<step.index(before: step.endIndex)]
        return (name, String(inner).trimmingCharacters(in: .whitespaces))
    }

    private func descendants(includingSelf: Bool) -> [XMLNode] {
        var out: [XMLNode] = includingSelf ? [self] : []
        for child in children ?? [] where child.kind == .element || child.kind == .document {
            out += child.descendants(includingSelf: true)
        }
        return out
    }
}

final class XMLElement: XMLNode {
    fileprivate(set) var attributes: [XMLNode]?

    init(name: String) { super.init(kind: .element, name: name) }

    func attribute(forName name: String) -> XMLNode? {
        attributes?.first { $0.name == name }
    }

    func elements(forName name: String) -> [XMLElement] {
        (children ?? []).compactMap { $0 as? XMLElement }.filter { $0.name == name }
    }

    fileprivate func addAttribute(_ name: String, _ value: String) {
        let node = XMLNode(kind: .attribute, name: name, value: value)
        node.parent = self
        if attributes == nil { attributes = [] }
        attributes!.append(node)
    }
}

enum XMLShimError: LocalizedError {
    case malformed(String)
    case xpath
    var errorDescription: String? {
        switch self {
        case .malformed(let m): return "XML을 읽을 수 없습니다: \(m)"
        case .xpath: return "지원하지 않는 XPath 식입니다."
        }
    }
}

final class XMLDocument: XMLNode {
    init(data: Data, options: XMLNode.Options = []) throws {
        super.init(kind: .document)
        var bytes = [UInt8](data)
        // UTF-16 files are rare in Office packages; normalise them to UTF-8.
        if bytes.count >= 2, (bytes[0] == 0xFF && bytes[1] == 0xFE) || (bytes[0] == 0xFE && bytes[1] == 0xFF) {
            let encoding: String.Encoding = bytes[0] == 0xFF ? .utf16LittleEndian : .utf16BigEndian
            guard let text = String(data: Data(bytes.dropFirst(2)), encoding: encoding) else { throw XMLShimError.malformed("UTF-16") }
            bytes = Array(text.utf8)
        }
        var parser = XMLShimParser(bytes: bytes, preserveWhitespace: options.contains(.nodePreserveWhitespace))
        try parser.parse(into: self)
        guard rootElement() != nil else { throw XMLShimError.malformed("루트 요소 없음") }
    }

    convenience init(xmlString: String, options: XMLNode.Options = []) throws {
        try self.init(data: Data(xmlString.utf8), options: options)
    }

    func rootElement() -> XMLElement? {
        (children ?? []).first { $0.kind == .element } as? XMLElement
    }
}

private struct XMLShimParser {
    let bytes: [UInt8]
    let preserveWhitespace: Bool
    var i = 0

    init(bytes: [UInt8], preserveWhitespace: Bool) {
        self.bytes = bytes
        self.preserveWhitespace = preserveWhitespace
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { i = 3 }
    }

    private static let lt = UInt8(ascii: "<"), gt = UInt8(ascii: ">"), slash = UInt8(ascii: "/")
    private static let amp = UInt8(ascii: "&"), eq = UInt8(ascii: "="), quote = UInt8(ascii: "\""), apos = UInt8(ascii: "'")
    private static let bang = UInt8(ascii: "!"), question = UInt8(ascii: "?")

    private func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D }
    private func isNameByte(_ b: UInt8) -> Bool {
        !(isSpace(b) || b == Self.gt || b == Self.slash || b == Self.eq || b == Self.lt || b == Self.quote || b == Self.apos)
    }

    private func starts(_ s: String, at p: Int) -> Bool {
        let u = Array(s.utf8)
        guard p + u.count <= bytes.count else { return false }
        for k in 0..<u.count where bytes[p + k] != u[k] { return false }
        return true
    }

    private func find(_ s: String, from p: Int) -> Int? {
        let u = Array(s.utf8)
        guard !u.isEmpty, bytes.count >= u.count else { return nil }
        var k = p
        let last = bytes.count - u.count
        while k <= last {
            if bytes[k] == u[0] {
                var ok = true
                for m in 1..<u.count where bytes[k + m] != u[m] { ok = false; break }
                if ok { return k }
            }
            k += 1
        }
        return nil
    }

    private func string(_ a: Int, _ b: Int) -> String {
        guard a < b else { return "" }
        return String(decoding: bytes[a..<b], as: UTF8.self)
    }

    mutating func parse(into document: XMLDocument) throws {
        var stack: [XMLNode] = [document]
        while i < bytes.count {
            if bytes[i] == Self.lt {
                if starts("<!--", at: i) {
                    guard let e = find("-->", from: i + 4) else { throw XMLShimError.malformed("주석이 닫히지 않음") }
                    i = e + 3
                } else if starts("<![CDATA[", at: i) {
                    guard let e = find("]]>", from: i + 9) else { throw XMLShimError.malformed("CDATA가 닫히지 않음") }
                    let text = string(i + 9, e)
                    if stack.count > 1 { stack[stack.count - 1].append(XMLNode(kind: .text, value: text)) }
                    i = e + 3
                } else if starts("<?", at: i) {
                    guard let e = find("?>", from: i + 2) else { throw XMLShimError.malformed("처리 명령이 닫히지 않음") }
                    i = e + 2
                } else if starts("<!", at: i) {
                    try skipDeclaration()
                } else if i + 1 < bytes.count, bytes[i + 1] == Self.slash {
                    var p = i + 2
                    let start = p
                    while p < bytes.count, isNameByte(bytes[p]) { p += 1 }
                    let name = string(start, p)
                    while p < bytes.count, bytes[p] != Self.gt { p += 1 }
                    i = min(bytes.count, p + 1)
                    // Lenient recovery: close up to the matching open element.
                    if let match = stack.lastIndex(where: { $0.kind == .element && $0.name == name }), match > 0 {
                        stack.removeSubrange(match...)
                    }
                } else {
                    try parseStartTag(&stack)
                }
            } else {
                let start = i
                while i < bytes.count, bytes[i] != Self.lt { i += 1 }
                guard stack.count > 1 else { continue }
                let raw = string(start, i)
                if !preserveWhitespace, raw.allSatisfy({ $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) { continue }
                let text = Self.decodeEntities(raw.replacingOccurrences(of: "\r\n", with: "\n"))
                stack[stack.count - 1].append(XMLNode(kind: .text, value: text))
            }
        }
    }

    private mutating func skipDeclaration() throws {
        var depth = 0
        var p = i + 2
        var quoteByte: UInt8?
        while p < bytes.count {
            let b = bytes[p]
            if let q = quoteByte { if b == q { quoteByte = nil } }
            else if b == Self.quote || b == Self.apos { quoteByte = b }
            else if b == UInt8(ascii: "[") { depth += 1 }
            else if b == UInt8(ascii: "]") { depth = max(0, depth - 1) }
            else if b == Self.gt && depth == 0 { i = p + 1; return }
            p += 1
        }
        throw XMLShimError.malformed("선언이 닫히지 않음")
    }

    private mutating func parseStartTag(_ stack: inout [XMLNode]) throws {
        var p = i + 1
        let start = p
        while p < bytes.count, isNameByte(bytes[p]) { p += 1 }
        guard p > start else { throw XMLShimError.malformed("요소 이름 없음") }
        let element = XMLElement(name: string(start, p))
        var selfClosing = false
        while p < bytes.count {
            while p < bytes.count, isSpace(bytes[p]) { p += 1 }
            guard p < bytes.count else { break }
            if bytes[p] == Self.gt { p += 1; break }
            if bytes[p] == Self.slash, p + 1 < bytes.count, bytes[p + 1] == Self.gt { selfClosing = true; p += 2; break }
            let nameStart = p
            while p < bytes.count, isNameByte(bytes[p]) { p += 1 }
            let attrName = string(nameStart, p)
            while p < bytes.count, isSpace(bytes[p]) { p += 1 }
            guard p < bytes.count, bytes[p] == Self.eq else {
                if p == nameStart { p += 1 }  // skip a stray byte and keep going
                continue
            }
            p += 1
            while p < bytes.count, isSpace(bytes[p]) { p += 1 }
            guard p < bytes.count, bytes[p] == Self.quote || bytes[p] == Self.apos else { throw XMLShimError.malformed("속성 값 따옴표 없음") }
            let q = bytes[p]
            p += 1
            let valueStart = p
            while p < bytes.count, bytes[p] != q { p += 1 }
            guard p < bytes.count else { throw XMLShimError.malformed("속성 값이 닫히지 않음") }
            var value = string(valueStart, p)
            p += 1
            // Attribute-value normalisation (XML 1.0 §3.3.3) before entity decoding.
            value = value.replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\t", with: " ")
            if !attrName.isEmpty { element.addAttribute(attrName, Self.decodeEntities(value)) }
        }
        i = p
        stack[stack.count - 1].append(element)
        if !selfClosing { stack.append(element) }
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        out.reserveCapacity(s.count)
        var rest = Substring(s)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let afterAmp = rest.index(after: amp)
            guard let semi = rest[afterAmp...].prefix(12).firstIndex(of: ";") else {
                out.append("&"); rest = rest[afterAmp...]; continue
            }
            let entity = rest[afterAmp..<semi]
            var replacement: String?
            switch entity {
            case "lt": replacement = "<"
            case "gt": replacement = ">"
            case "amp": replacement = "&"
            case "quot": replacement = "\""
            case "apos": replacement = "'"
            default:
                if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                    if let v = UInt32(entity.dropFirst(2), radix: 16), let u = Unicode.Scalar(v) { replacement = String(Character(u)) }
                } else if entity.hasPrefix("#") {
                    if let v = UInt32(entity.dropFirst()), let u = Unicode.Scalar(v) { replacement = String(Character(u)) }
                }
            }
            if let replacement {
                out += replacement
                rest = rest[rest.index(after: semi)...]
            } else {
                out.append("&")
                rest = rest[afterAmp...]
            }
        }
        out += rest
        return out
    }
}

#endif
