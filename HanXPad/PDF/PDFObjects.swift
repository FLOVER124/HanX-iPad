import UIKit
import PDFKit

/// An editable object found on a PDF page. Bounds are in PDF page space
/// (unrotated user space, origin bottom-left), like pdfium object bounds in
/// the macOS editor.
struct PDFPageObject: Equatable {
    enum Kind: String { case text, image, path }
    var id: Int
    var kind: Kind
    var bounds: CGRect
    var text: String = ""
    var fontSize: CGFloat = 12
    var fontName: String = ""
    var bold = false
    var italic = false
    var color: RGB = .black

    var title: String {
        switch kind {
        case .text: return text.isEmpty ? "텍스트" : text
        case .image: return "이미지"
        case .path: return "도형"
        }
    }
    var typeTitle: String {
        switch kind {
        case .text: return "텍스트"
        case .image: return "이미지"
        case .path: return "도형"
        }
    }
}

enum PDFObjectFinder {
    /// Text lines from PDFKit plus images and painted paths from the content stream.
    static func objects(on page: PDFPage, groupPaths: Bool = true) -> [PDFPageObject] {
        var out: [PDFPageObject] = []
        let box = page.bounds(for: .mediaBox)
        if let all = page.selection(for: box) {
            for line in all.selectionsByLine() {
                let raw = line.string ?? ""
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let r = line.bounds(for: page)
                guard r.width > 0.5, r.height > 0.5 else { continue }
                var o = PDFPageObject(id: out.count, kind: .text, bounds: r, text: text)
                if let attributed = line.attributedString, attributed.length > 0 {
                    let a = attributed.attributes(at: 0, effectiveRange: nil)
                    if let font = a[.font] as? UIFont {
                        o.fontSize = font.pointSize
                        o.fontName = cleanFontName(font.fontName)
                        let traits = font.fontDescriptor.symbolicTraits
                        o.bold = traits.contains(.traitBold) || font.fontName.lowercased().contains("bold")
                        o.italic = traits.contains(.traitItalic) || font.fontName.lowercased().contains("italic")
                    }
                    if let color = a[.foregroundColor] as? UIColor { o.color = RGB(color) }
                }
                if o.fontSize <= 1 || o.fontSize > r.height * 2 { o.fontSize = max(4, r.height * 0.8) }
                out.append(o)
            }
        }
        if let ref = page.pageRef {
            let scanner = PDFContentScanner()
            scanner.scan(ref)
            for r in scanner.images where r.width > 1 && r.height > 1 {
                out.append(PDFPageObject(id: out.count, kind: .image, bounds: r.intersection(box.insetBy(dx: -2, dy: -2))))
            }
            let paths = groupPaths ? cluster(scanner.paths, excluding: out.filter { $0.kind == .text }.map(\.bounds), page: box) : scanner.paths
            for r in paths where r.width > 1 || r.height > 1 {
                // Full-page backgrounds are not useful selection targets.
                if r.width >= box.width * 0.98 && r.height >= box.height * 0.98 { continue }
                out.append(PDFPageObject(id: out.count, kind: .path, bounds: r))
            }
        }
        return out
    }

    static func cleanFontName(_ name: String) -> String {
        // Embedded subsets are named "ABCDEF+FontName".
        if let plus = name.firstIndex(of: "+"), name.distance(from: name.startIndex, to: plus) == 6 { return String(name[name.index(after: plus)...]) }
        return name
    }

    /// Merges touching path fragments (outlined lettering, hatching) into
    /// one object; fragments inside text lines are dropped.
    static func cluster(_ rects: [CGRect], excluding text: [CGRect], page: CGRect) -> [CGRect] {
        var items = rects.filter { r in !text.contains { $0.insetBy(dx: -1, dy: -1).contains(r) } }
        if items.count > 3000 { items = Array(items.prefix(3000)) }
        var merged = true
        while merged {
            merged = false
            var out: [CGRect] = []
            for r in items {
                if let i = out.firstIndex(where: { $0.insetBy(dx: -1.5, dy: -1.5).intersects(r) && max($0.width, $0.height) < page.width * 0.6 }) {
                    out[i] = out[i].union(r)
                    merged = true
                } else {
                    out.append(r)
                }
            }
            items = out
        }
        return items
    }
}

/// Walks a page's content stream (recursing into form XObjects) and records
/// where images are drawn and which paths are painted, in page space.
final class PDFContentScanner {
    private(set) var images: [CGRect] = []
    private(set) var paths: [CGRect] = []
    private var ctm = CGAffineTransform.identity
    private var stack: [CGAffineTransform] = []
    private var pathBox: CGRect?
    private var current = CGPoint.zero
    private var depth = 0
    private var table: CGPDFOperatorTableRef?

    func scan(_ page: CGPDFPage) {
        guard let table = CGPDFOperatorTableCreate() else { return }
        self.table = table
        register(table)
        let stream = CGPDFContentStreamCreateWithPage(page)
        run(stream)
        CGPDFOperatorTableRelease(table)
        self.table = nil
    }

    private func run(_ stream: CGPDFContentStreamRef) {
        guard let table else { return }
        let info = Unmanaged.passUnretained(self).toOpaque()
        let scanner = CGPDFScannerCreate(stream, table, info)
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
    }

    private static func me(_ info: UnsafeMutableRawPointer?) -> PDFContentScanner? {
        guard let info else { return nil }
        return Unmanaged<PDFContentScanner>.fromOpaque(info).takeUnretainedValue()
    }

    private static func numbers(_ scanner: CGPDFScannerRef, _ count: Int) -> [CGFloat]? {
        var values = [CGFloat](repeating: 0, count: count)
        for i in (0..<count).reversed() {
            var v: CGPDFReal = 0
            guard CGPDFScannerPopNumber(scanner, &v) else { return nil }
            values[i] = CGFloat(v)
        }
        return values
    }

    private func add(_ p: CGPoint) {
        let t = p.applying(ctm)
        pathBox = pathBox.map { $0.union(CGRect(origin: t, size: .zero)) } ?? CGRect(origin: t, size: .zero)
        current = p
    }

    private func paint() {
        if let box = pathBox, box.width.isFinite, box.height.isFinite, paths.count < 20_000 { paths.append(box) }
        pathBox = nil
    }

    private func register(_ table: CGPDFOperatorTableRef) {
        CGPDFOperatorTableSetCallback(table, "q") { _, info in
            guard let me = PDFContentScanner.me(info) else { return }
            me.stack.append(me.ctm)
        }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in
            guard let me = PDFContentScanner.me(info) else { return }
            if let last = me.stack.popLast() { me.ctm = last }
        }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            guard let me = PDFContentScanner.me(info), let n = PDFContentScanner.numbers(scanner, 6) else { return }
            me.ctm = CGAffineTransform(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5]).concatenating(me.ctm)
        }
        CGPDFOperatorTableSetCallback(table, "m") { scanner, info in
            guard let me = PDFContentScanner.me(info), let n = PDFContentScanner.numbers(scanner, 2) else { return }
            me.add(CGPoint(x: n[0], y: n[1]))
        }
        CGPDFOperatorTableSetCallback(table, "l") { scanner, info in
            guard let me = PDFContentScanner.me(info), let n = PDFContentScanner.numbers(scanner, 2) else { return }
            me.add(CGPoint(x: n[0], y: n[1]))
        }
        CGPDFOperatorTableSetCallback(table, "c") { scanner, info in
            guard let me = PDFContentScanner.me(info), let n = PDFContentScanner.numbers(scanner, 6) else { return }
            me.add(CGPoint(x: n[0], y: n[1])); me.add(CGPoint(x: n[2], y: n[3])); me.add(CGPoint(x: n[4], y: n[5]))
        }
        for op in ["v", "y"] {
            CGPDFOperatorTableSetCallback(table, op) { scanner, info in
                guard let me = PDFContentScanner.me(info), let n = PDFContentScanner.numbers(scanner, 4) else { return }
                me.add(CGPoint(x: n[0], y: n[1])); me.add(CGPoint(x: n[2], y: n[3]))
            }
        }
        CGPDFOperatorTableSetCallback(table, "re") { scanner, info in
            guard let me = PDFContentScanner.me(info), let n = PDFContentScanner.numbers(scanner, 4) else { return }
            me.add(CGPoint(x: n[0], y: n[1])); me.add(CGPoint(x: n[0] + n[2], y: n[1] + n[3]))
        }
        for op in ["f", "F", "f*", "S", "s", "B", "B*", "b", "b*"] {
            CGPDFOperatorTableSetCallback(table, op) { _, info in PDFContentScanner.me(info)?.paint() }
        }
        CGPDFOperatorTableSetCallback(table, "n") { _, info in PDFContentScanner.me(info)?.pathBox = nil }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            guard let me = PDFContentScanner.me(info) else { return }
            var namePtr: UnsafePointer<Int8>?
            guard CGPDFScannerPopName(scanner, &namePtr), let namePtr else { return }
            let cs = CGPDFScannerGetContentStream(scanner)
            guard let object = CGPDFContentStreamGetResource(cs, "XObject", namePtr) else { return }
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream, let dict = CGPDFStreamGetDictionary(stream) else { return }
            var subtype: UnsafePointer<Int8>?
            guard CGPDFDictionaryGetName(dict, "Subtype", &subtype), let subtype else { return }
            let kind = String(cString: subtype)
            if kind == "Image" {
                let unit = CGRect(x: 0, y: 0, width: 1, height: 1).applying(me.ctm)
                me.images.append(unit.standardized)
            } else if kind == "Form", me.depth < 12 {
                var matrix = CGAffineTransform.identity
                var array: CGPDFArrayRef?
                if CGPDFDictionaryGetArray(dict, "Matrix", &array), let array, CGPDFArrayGetCount(array) == 6 {
                    var v = [CGFloat](repeating: 0, count: 6)
                    for i in 0..<6 { var n: CGPDFReal = 0; if CGPDFArrayGetNumber(array, i, &n) { v[i] = CGFloat(n) } }
                    matrix = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
                }
                var resources: CGPDFDictionaryRef?
                _ = CGPDFDictionaryGetDictionary(dict, "Resources", &resources)
                let saved = me.ctm
                me.ctm = matrix.concatenating(me.ctm)
                me.depth += 1
                let child = CGPDFContentStreamCreateWithStream(stream, resources ?? dict, cs)
                me.run(child)
                CGPDFContentStreamRelease(child)
                me.depth -= 1
                me.ctm = saved
            }
        }
    }
}
