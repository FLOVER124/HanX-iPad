import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Unified Document Model (UDM).
//
// Both source applications converge on the same shape once their storage
// details are stripped away: HWP keeps shared CharShape/ParaShape tables in
// DocInfo and references them by ID from each paragraph, while Word keeps
// style definitions plus direct run/paragraph properties. Importers resolve
// both into fully-specified properties per run/paragraph, so the editor and
// the writers never need to know which format a document came from.
// All lengths are in typographic points.

struct RGB: Equatable, Hashable, Codable {
    var r: UInt8, g: UInt8, b: UInt8

    static let black = RGB(r: 0, g: 0, b: 0)
    static let white = RGB(r: 255, g: 255, b: 255)

    /// HWP COLORREF is 0x00BBGGRR.
    init(colorref v: UInt32) { r = UInt8(v & 0xFF); g = UInt8((v >> 8) & 0xFF); b = UInt8((v >> 16) & 0xFF) }
    init(r: UInt8, g: UInt8, b: UInt8) { self.r = r; self.g = g; self.b = b }
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        r = UInt8(v >> 16); g = UInt8((v >> 8) & 0xFF); b = UInt8(v & 0xFF)
    }

    var hex: String { String(format: "%02X%02X%02X", r, g, b) }
    var colorref: UInt32 { UInt32(r) | UInt32(g) << 8 | UInt32(b) << 16 }
}

enum UnderlineStyle: String, Codable { case none, single, double, dotted, dashed, wave, thick }
enum VerticalAlign: String, Codable { case baseline, superscript, `subscript` }

struct CharProps: Equatable, Codable {
    var fontName: String = "함초롬바탕"
    /// East-Asian face when it differs from the Latin face (HWP keeps 7
    /// per-script faces; Word keeps ascii/eastAsia/cs/hAnsi).
    var eastAsianFontName: String?
    var size: Double = 10
    var bold = false
    var italic = false
    var underline: UnderlineStyle = .none
    var strike = false
    var color: RGB = .black
    var highlight: RGB?
    var verticalAlign: VerticalAlign = .baseline
    /// Letter spacing in points (positive expands).
    var spacing: Double = 0
    /// Glyph width scale in percent (HWP 장평, Word w:w).
    var widthRatio: Double = 100
}

enum Alignment: String, Codable { case left, right, center, justify, distribute }

enum LineSpacing: Equatable, Codable {
    /// Multiple of the font's natural line height (Word "auto" rule).
    case multiple(Double)
    /// Percent of the font size (HWP "글자에 따라" rule): pitch = size * p / 100.
    case percentOfSize(Double)
    case exact(Double)
    case atLeast(Double)
}

struct ParaProps: Equatable, Codable {
    var alignment: Alignment = .justify
    var indentLeft: Double = 0
    var indentRight: Double = 0
    /// Relative to indentLeft (Word semantics): positive = first-line
    /// indent, negative = hanging indent.
    var firstLine: Double = 0
    var spaceBefore: Double = 0
    var spaceAfter: Double = 0
    var lineSpacing: LineSpacing = .percentOfSize(160)
    var bottomBorder: BorderLine?
    var pageBreakBefore = false
    var styleName: String?
    var listLabel: String?
}

struct ImageData: Codable {
    var name: String
    var data: Data
    var ext: String { (name as NSString).pathExtension.lowercased() }
}

enum FieldKind: String, Codable { case page, pageCount }

enum Inline: Codable {
    case text(String, CharProps)
    case tab(CharProps)
    case lineBreak(CharProps)
    case pageBreak
    /// `id` keys into UDocument.images; size in points.
    case image(id: String, width: Double, height: Double)
    /// Page number / page count, resolved when a page is drawn.
    case field(FieldKind, CharProps)
}

struct Paragraph: Codable {
    var props = ParaProps()
    var inlines: [Inline] = []
    /// Character properties for an empty paragraph's mark.
    var markProps = CharProps()

    var plainText: String {
        inlines.map {
            switch $0 {
            case .text(let s, _): return s
            case .tab: return "\t"
            case .lineBreak: return "\n"
            case .pageBreak: return "\u{0C}"
            case .image: return "\u{FFFC}"
            case .field(let k, _): return k == .page ? "#" : "##"
            }
        }.joined()
    }
}

enum BorderStyle: String, Codable { case none, solid, dotted, dashed, double }

struct BorderLine: Equatable, Hashable, Codable {
    var style: BorderStyle = .solid
    var width: Double = 0.5
    var color: RGB = .black

    static let none = BorderLine(style: .none, width: 0, color: .black)
    static let thin = BorderLine()
    var visible: Bool { style != .none && width > 0 }
}

/// Order: left, right, top, bottom (HWP's BorderFill order).
struct CellBorders: Equatable, Hashable, Codable {
    var left = BorderLine.thin, right = BorderLine.thin, top = BorderLine.thin, bottom = BorderLine.thin
    static let all = CellBorders()
    static let none = CellBorders(left: .none, right: .none, top: .none, bottom: .none)
}

struct Insets: Equatable, Hashable, Codable {
    var left: Double, right: Double, top: Double, bottom: Double
    static let hwpDefault = Insets(left: 5.1, right: 5.1, top: 1.41, bottom: 1.41)
    static let wordDefault = Insets(left: 5.4, right: 5.4, top: 0, bottom: 0)
}

enum CellVAlign: String, Codable { case top, center, bottom }

struct TableCell: Codable {
    var blocks: [Block] = []
    var colSpan = 1
    var rowSpan = 1
    var width: Double?
    /// Total cell height (border box) in points; content may grow it.
    var height: Double?
    var padding: Insets?
    var verticalAlign: CellVAlign = .top
    var borders = CellBorders.all
    var background: RGB?
    /// Covered by another cell's span; kept so every row has gridCols slots.
    var isMergedAway = false
}

struct Table: Codable {
    var rows: [[TableCell]] = []
    var columnWidths: [Double] = []
    var borderWidth: Double = 0.5

    /// Rows hold one slot per grid column (covered slots included).
    var columnCount: Int { max(columnWidths.count, rows.map(\.count).max() ?? 0) }
}

indirect enum Block: Codable {
    case paragraph(Paragraph)
    case table(Table)
}

struct PageSetup: Equatable, Codable {
    var width: Double = 595.3    // A4
    var height: Double = 841.9
    var marginTop: Double = 56.7
    var marginBottom: Double = 42.5
    var marginLeft: Double = 85.0
    var marginRight: Double = 85.0
    var header: Double = 42.5
    var footer: Double = 42.5

    var contentWidth: Double { max(72, width - marginLeft - marginRight) }
    var contentHeight: Double { max(72, height - marginTop - marginBottom) }

    static let a4Hwp = PageSetup()
    static let letterWord = PageSetup(width: 612, height: 792, marginTop: 72, marginBottom: 72, marginLeft: 72, marginRight: 72, header: 36, footer: 36)
}

struct Section: Codable {
    var page = PageSetup()
    var blocks: [Block] = []
    /// 머리말 / 꼬리말 (Word header/footer); nil when absent.
    var header: [Block]?
    var footer: [Block]?
}

enum SourceFormat: String, Codable { case hwp, hwpx, docx, unknown }

final class UDocument {
    var sections: [Section] = []
    var images: [String: ImageData] = [:]
    var title: String?
    var source: SourceFormat = .unknown
    var warnings: [String] = []

    var plainText: String {
        sections.flatMap(\.blocks).map(Self.text(of:)).joined(separator: "\n")
    }

    static func plain(_ text: String, char: CharProps) -> UDocument {
        let d = UDocument()
        var section = Section(page: .a4Hwp, blocks: [])
        for line in text.components(separatedBy: "\n") {
            var p = Paragraph()
            p.markProps = char
            p.props.alignment = .left
            p.props.lineSpacing = .multiple(1.15)
            if !line.isEmpty {
                var parts = line.components(separatedBy: "\t")
                p.inlines.append(.text(parts.removeFirst(), char))
                for part in parts { p.inlines.append(.tab(char)); if !part.isEmpty { p.inlines.append(.text(part, char)) } }
            }
            section.blocks.append(.paragraph(p))
        }
        d.sections = [section]
        return d
    }

    static func text(of block: Block) -> String {
        switch block {
        case .paragraph(let p): return p.plainText
        case .table(let t):
            return t.rows.map { row in
                row.filter { !$0.isMergedAway }.map { $0.blocks.map(text(of:)).joined(separator: "\n") }.joined(separator: "\t")
            }.joined(separator: "\n")
        }
    }

    var stats: (paragraphs: Int, tables: Int, images: Int) {
        var p = 0, t = 0, i = 0
        func walk(_ blocks: [Block]) {
            for b in blocks {
                switch b {
                case .paragraph(let para):
                    p += 1
                    i += para.inlines.filter { if case .image = $0 { return true }; return false }.count
                case .table(let tb):
                    t += 1
                    tb.rows.forEach { $0.forEach { walk($0.blocks) } }
                }
            }
        }
        sections.forEach { walk($0.blocks) }
        return (p, t, i)
    }
}

enum Units {
    /// HWPUNIT = 1/7200 inch.
    static func hwp(_ v: Int32) -> Double { Double(v) / 100 }
    static func hwp(_ v: UInt32) -> Double { Double(v) / 100 }
    static func toHwp(_ pt: Double) -> Int32 { Int32((pt * 100).rounded()) }
    /// Twentieths of a point.
    static func twips(_ v: Double) -> Double { v / 20 }
    static func toTwips(_ pt: Double) -> Int { Int((pt * 20).rounded()) }
    /// English Metric Units (914400 per inch).
    static func emu(_ v: Double) -> Double { v / 12700 }
    static func toEmu(_ pt: Double) -> Int { Int((pt * 12700).rounded()) }
}
