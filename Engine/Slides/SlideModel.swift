import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Presentation model ("프레젠테이션"). Text inside shapes reuses the
/// document model's Paragraph type, so the same TextKit bridge renders and
/// edits slide text, document text and table cells.

struct Frame: Equatable, Codable {
    var x: Double, y: Double, w: Double, h: Double
    static let zero = Frame(x: 0, y: 0, w: 0, h: 0)
    var maxX: Double { x + w }
    var maxY: Double { y + h }
}

enum ShapeKind: String, CaseIterable, Codable {
    case text, rect, roundRect, ellipse, triangle, rightArrow, line, image, table
    case diamond, pentagon, hexagon, octagon, star5, star6, heart, plus
    case leftArrow, upArrow, downArrow, leftRightArrow, chevron, parallelogram, trapezoid
    var title: String {
        let titles = ["text":"텍스트 상자", "rect":"사각형", "roundRect":"둥근 사각형", "ellipse":"타원", "triangle":"삼각형", "rightArrow":"오른쪽 화살표", "line":"선", "image":"그림", "table":"표", "diamond":"마름모", "pentagon":"오각형", "hexagon":"육각형", "octagon":"팔각형", "star5":"별 (5각)", "star6":"별 (6각)", "heart":"하트", "plus":"십자", "leftArrow":"왼쪽 화살표", "upArrow":"위쪽 화살표", "downArrow":"아래쪽 화살표", "leftRightArrow":"양쪽 화살표", "chevron":"갈매기형", "parallelogram":"평행사변형", "trapezoid":"사다리꼴"]
        return titles[rawValue] ?? rawValue
    }
}

struct SlideShape: Codable {
    var id = 0
    var name = ""
    var kind: ShapeKind = .text
    var frame = Frame.zero
    var rotation: Double = 0
    var flipH = false, flipV = false
    var lockAspect = false
    var fill: RGB?
    var line: RGB?
    var lineWidth: Double = 0.75
    var paragraphs: [Paragraph] = []
    var anchor: CellVAlign = .top
    var insets = Insets(left: 7.2, right: 7.2, top: 3.6, bottom: 3.6)
    var wrap = true
    var autofitScale: Double = 1
    var imageID: String?
    /// An embedded movie uses imageID for its editable poster.
    var videoID: String?
    var table: Table?
    var tableRowHeights: [Double] = []
    var placeholder: String?
    /// Decoration inherited from the slide layout/master; drawn but not selectable.
    var locked = false
    /// cNvPr ids of this shape and its enclosing groups in the source file,
    /// used to resolve animation targets.
    var sourceIDs: [Int] = []

    var hasText: Bool { paragraphs.contains { !$0.plainText.isEmpty } }
}

/// PowerPoint animation effects, keyed by their PresentationML preset IDs.
enum AnimClass: String, CaseIterable, Codable { case entrance = "entr", emphasis = "emph", exit = "exit" }

enum AnimEffect: String, CaseIterable, Codable {
    // entrance
    case appear, fade, flyIn, floatIn, wipe, split, zoom, wheel
    // emphasis
    case spin, growShrink, transparency, pulse
    // exit
    case disappear, fadeOut, flyOut, floatOut, wipeOut, splitOut, zoomOut

    var animClass: AnimClass {
        switch self {
        case .appear, .fade, .flyIn, .floatIn, .wipe, .split, .zoom, .wheel: return .entrance
        case .spin, .growShrink, .transparency, .pulse: return .emphasis
        default: return .exit
        }
    }

    var title: String {
        [.appear: "나타내기", .fade: "밝기 변화", .flyIn: "날아오기", .floatIn: "떠오르기", .wipe: "닦아내기", .split: "다이아몬드 나누기",
         .zoom: "확대/축소", .wheel: "시계 방향 회전", .spin: "회전", .growShrink: "크게/작게", .transparency: "투명", .pulse: "펄스",
         .disappear: "사라지기", .fadeOut: "밝기 변화", .flyOut: "날아가기", .floatOut: "떠내려가기", .wipeOut: "닦아내기",
         .splitOut: "나누기", .zoomOut: "확대/축소"][self]!
    }

    /// PresentationML presetID for this effect within its class.
    var presetID: Int {
        [.appear: 1, .flyIn: 2, .fade: 10, .split: 16, .wheel: 21, .wipe: 22, .zoom: 23, .floatIn: 42,
         .growShrink: 6, .spin: 8, .transparency: 9, .pulse: 26,
         .disappear: 1, .flyOut: 2, .fadeOut: 10, .splitOut: 16, .wipeOut: 22, .zoomOut: 23, .floatOut: 42][self]!
    }

    static func from(presetClass: String, id: Int) -> AnimEffect {
        let cls = AnimClass(rawValue: presetClass) ?? .entrance
        if let e = allCases.first(where: { $0.animClass == cls && $0.presetID == id }) { return e }
        switch cls {
        case .entrance: return .fade
        case .emphasis: return .pulse
        case .exit: return .fadeOut
        }
    }

    var defaultDuration: Double {
        switch self {
        case .appear, .disappear: return 0
        case .spin: return 2
        case .growShrink: return 2
        default: return 0.5
        }
    }
}

enum AnimTrigger: String, CaseIterable, Codable {
    case onClick = "clickEffect", withPrevious = "withEffect", afterPrevious = "afterEffect"
    var title: String { [.onClick: "클릭할 때", .withPrevious: "이전 효과와 함께", .afterPrevious: "이전 효과 다음에"][self]! }
}

enum AnimDirection: String, CaseIterable, Codable {
    case bottom, left, right, top
    var title: String { [.bottom: "아래에서", .left: "왼쪽에서", .right: "오른쪽에서", .top: "위에서"][self]! }
    /// presetSubtype bit for fly/wipe directions.
    var subtype: Int { [.top: 1, .right: 2, .bottom: 4, .left: 8][self]! }
    static func from(subtype: Int) -> AnimDirection { allCases.first { $0.subtype == subtype } ?? .bottom }
}

struct SlideAnimation: Equatable, Codable {
    var shapeID: Int
    var effect: AnimEffect
    var trigger: AnimTrigger = .onClick
    var duration: Double = 0.5          // seconds
    var delay: Double = 0
    var direction: AnimDirection = .bottom
}

enum TransitionKind: String, CaseIterable, Codable {
    case none, fade, push, wipe, cover, pull, split, zoom, dissolve, cut
    case blinds, checker, comb, randomBar, strips, circle, diamond, plus, wedge, wheel, newsflash
    var title: String {
        [.none: "없음", .fade: "페이드", .push: "밀어내기", .wipe: "닦아내기", .cover: "덮기", .pull: "당기기",
         .split: "나누기", .zoom: "확대/축소", .dissolve: "디졸브", .cut: "잘라내기",
         .blinds: "블라인드", .checker: "체커보드", .comb: "빗질", .randomBar: "임의의 막대", .strips: "대각선 줄무늬", .circle: "원형", .diamond: "마름모", .plus: "십자", .wedge: "쐐기", .wheel: "바퀴", .newsflash: "뉴스 속보"][self]!
    }
}

struct SlideTransition: Equatable, Codable {
    var kind: TransitionKind = .none
    var duration: Double = 0.7
    var direction: AnimDirection = .right
    /// Advance automatically after this many seconds (nil = on click only).
    var advanceAfter: Double?
    var advanceOnClick = true
    var vertical = false
    var inward = false
}

struct Slide: Codable {
    var shapes: [SlideShape] = []
    var animations: [SlideAnimation] = []
    var transition = SlideTransition()
    var background: RGB? = RGB(r: 255, g: 255, b: 255)
    var backgroundImage: String?
    // Optional fields keep older slide JSON readable.
    var backgroundEnd: RGB?
    var backgroundMiddle: RGB?
    var backgroundMiddlePosition: Double?
    var middleFraction: Double {
        let position = backgroundMiddlePosition ?? 50
        return position.isFinite ? max(0.00001, min(0.99999, position / 100)) : 0.5
    }
    var backgroundAngle: Double?
    var gradientAngle: Double {
        let value = backgroundAngle ?? 0
        return value.isFinite ? (value.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) : 0
    }
    mutating func copyBackground(from source: Slide) {
        background = source.background
        backgroundEnd = source.backgroundEnd
        backgroundAngle = source.backgroundAngle
        backgroundMiddle = source.backgroundMiddle
        backgroundMiddlePosition = source.backgroundMiddlePosition
        backgroundImage = source.backgroundImage
    }
    var notes = ""
}

final class Presentation {
    var width: Double = 960       // 13.333 in × 72 (16:9)
    var height: Double = 540
    var slides: [Slide] = []
    var images: [String: ImageData] = [:]
    var source = "pptx"

    static func blank() -> Presentation {
        let p = Presentation()
        p.slides = [p.titleSlide()]
        return p
    }

    func nextID(_ slide: Slide) -> Int { (slide.shapes.map(\.id).max() ?? 1) + 1 }

    static func textParagraph(_ text: String, size: Double, bold: Bool = false, align: Alignment = .left, color: RGB = .black) -> Paragraph {
        var c = CharProps()
        c.fontName = "맑은 고딕"; c.eastAsianFontName = "맑은 고딕"
        c.size = size; c.bold = bold; c.color = color
        var p = Paragraph()
        p.props.alignment = align
        p.props.lineSpacing = .multiple(0.9)
        p.markProps = c
        if !text.isEmpty { p.inlines = [.text(text, c)] }
        return p
    }

    func titleSlide() -> Slide {
        var s = Slide()
        var title = SlideShape(id: 2, name: "제목", kind: .text, frame: Frame(x: width * 0.1, y: height * 0.28, w: width * 0.8, h: height * 0.22))
        title.paragraphs = [Presentation.textParagraph("", size: 44, bold: true, align: .center)]
        title.anchor = .bottom
        title.placeholder = "ctrTitle"
        var sub = SlideShape(id: 3, name: "부제목", kind: .text, frame: Frame(x: width * 0.15, y: height * 0.54, w: width * 0.7, h: height * 0.16))
        sub.paragraphs = [Presentation.textParagraph("", size: 24, align: .center, color: RGB(r: 89, g: 89, b: 89))]
        sub.placeholder = "subTitle"
        s.shapes = [title, sub]
        return s
    }

    func contentSlide() -> Slide {
        var s = Slide()
        var title = SlideShape(id: 2, name: "제목", kind: .text, frame: Frame(x: width * 0.07, y: height * 0.06, w: width * 0.86, h: height * 0.16))
        title.paragraphs = [Presentation.textParagraph("", size: 36, bold: true)]
        title.anchor = .center
        title.placeholder = "title"
        var body = SlideShape(id: 3, name: "내용", kind: .text, frame: Frame(x: width * 0.07, y: height * 0.26, w: width * 0.86, h: height * 0.66))
        var p = Presentation.textParagraph("", size: 24)
        p.props.listLabel = "•"
        body.paragraphs = [p]
        body.placeholder = "body"
        s.shapes = [title, body]
        return s
    }

    var plainText: String {
        slides.enumerated().map { i, s in
            "[\(i + 1)] " + s.shapes.filter { !$0.locked }.flatMap { shape -> [String] in
                var text = shape.paragraphs.map(\.plainText)
                if let table = shape.table { text.append(UDocument.text(of: .table(table))) }
                return text
            }.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}

// MARK: - DrawingML helpers shared by reader and writer

enum DrawingML {
    static let emuPerPt = 12700.0

    static func pt(_ emu: Double?) -> Double { (emu ?? 0) / emuPerPt }
    static func emu(_ pt: Double) -> Int { Int((pt * emuPerPt).rounded()) }

    static func rgbToHSL(_ c: RGB) -> (Double, Double, Double) {
        let r = Double(c.r) / 255, g = Double(c.g) / 255, b = Double(c.b) / 255
        let mx = max(r, g, b), mn = min(r, g, b)
        let l = (mx + mn) / 2
        guard mx != mn else { return (0, 0, l) }
        let d = mx - mn
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        var h: Double
        if mx == r { h = (g - b) / d + (g < b ? 6 : 0) } else if mx == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
        h /= 6
        return (h, s, l)
    }

    static func hslToRGB(_ h: Double, _ s: Double, _ l: Double) -> RGB {
        func f(_ p: Double, _ q: Double, _ t0: Double) -> Double {
            var t = t0
            if t < 0 { t += 1 }; if t > 1 { t -= 1 }
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
            return p
        }
        let r, g, b: Double
        if s == 0 { r = l; g = l; b = l } else {
            let q = l < 0.5 ? l * (1 + s) : l + s - l * s
            let p = 2 * l - q
            r = f(p, q, h + 1 / 3); g = f(p, q, h); b = f(p, q, h - 1 / 3)
        }
        func u(_ v: Double) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
        return RGB(r: u(r), g: u(g), b: u(b))
    }

    /// Applies lumMod/lumOff/tint/shade children of a colour element.
    static func modify(_ base: RGB, _ e: XMLElement) -> RGB {
        var c = base
        for m in e.elementChildren {
            let v = (m.attrDouble("val") ?? 100000) / 100000
            switch m.local {
            case "lumMod": let (h, s, l) = rgbToHSL(c); c = hslToRGB(h, s, min(1, l * v))
            case "lumOff": let (h, s, l) = rgbToHSL(c); c = hslToRGB(h, s, min(1, l + v))
            case "tint":
                func t(_ x: UInt8) -> UInt8 { UInt8(min(255, Double(x) + (255 - Double(x)) * (1 - v))) }
                c = RGB(r: t(c.r), g: t(c.g), b: t(c.b))
            case "shade":
                func s(_ x: UInt8) -> UInt8 { UInt8(Double(x) * v) }
                c = RGB(r: s(c.r), g: s(c.g), b: s(c.b))
            default: break
            }
        }
        return c
    }
}

/// Pure slide geometry shared by canvas interaction and regression tests.
enum ShapeGeometry {
    static func rotated(_ x: Double, _ y: Double, _ degrees: Double) -> (Double, Double) {
        let a = degrees * .pi / 180
        return (x * cos(a) - y * sin(a), x * sin(a) + y * cos(a))
    }
    static func world(x: Double, y: Double, frame: Frame, rotation: Double) -> (Double, Double) {
        let c = (frame.x + frame.w / 2, frame.y + frame.h / 2)
        let r = rotated(x-c.0, y-c.1, rotation)
        return (c.0+r.0, c.1+r.1)
    }
    static func local(x: Double, y: Double, frame: Frame, rotation: Double) -> (Double, Double) {
        world(x:x, y:y, frame:frame, rotation:-rotation)
    }
    static func resized(_ f: Frame, rotation: Double, handle: Int, dx: Double, dy: Double, preserveAspect: Bool) -> Frame {
        let delta = rotated(dx,dy,-rotation)
        let left = [0,6,7].contains(handle), right = [2,3,4].contains(handle)
        let top = [0,1,2].contains(handle), bottom = [4,5,6].contains(handle)
        var w = max(1, f.w + (left ? -delta.0 : right ? delta.0 : 0))
        var h = max(1, f.h + (top ? -delta.1 : bottom ? delta.1 : 0))
        if preserveAspect && f.w > 0 && f.h > 0 {
            var scale: Double
            if !left && !right { scale = h/f.h }
            else if !top && !bottom { scale = w/f.w }
            else { scale = abs(w/f.w-1) > abs(h/f.h-1) ? w/f.w : h/f.h }
            scale = max(scale, 1/min(f.w,f.h))
            w = f.w*scale; h = f.h*scale
        }
        let cx = left ? (f.w-w)/2 : right ? (w-f.w)/2 : 0
        let cy = top ? (f.h-h)/2 : bottom ? (h-f.h)/2 : 0
        let d = rotated(cx,cy,rotation)
        return Frame(x:f.x+f.w/2+d.0-w/2, y:f.y+f.h/2+d.1-h/2, w:w, h:h)
    }
    static func bounds(_ s: SlideShape) -> Frame {
        let f=s.frame
        let pts=[(f.x,f.y),(f.maxX,f.y),(f.maxX,f.maxY),(f.x,f.maxY)].map { world(x:$0.0,y:$0.1,frame:f,rotation:s.rotation) }
        let x=pts.map { $0.0 }.min()!, y=pts.map { $0.1 }.min()!
        return Frame(x:x,y:y,w:pts.map { $0.0 }.max()!-x,h:pts.map { $0.1 }.max()!-y)
    }
}

enum SlideMovie {
    static let posterKey = "hanx/default-movie-poster.png"
    static let poster = ImageData(name: "movie-poster.png", data: Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAFAAAAAtCAIAAAC2z3vlAAAAqUlEQVR4nO3RsQ3DQBTDUA+T3hN4/21SpHFrD5EvEncCOIAedHzOa6sOfEHBBRdccMEFj4O/v/sN56XBQnYCrDKHwB52FGxgA2DWzIBBNglG2Dw4bFaAk2wROMPWgafNRvAo2wseYtvBfzfbwRs9PDTMCB6aJAWPal3gaaoInKFawEktDA5TSTBCxcCgNg1mqVEw7oyCcWQOjPNyYG0Fr17Bq1fw6m0HfgBSWlZt7iPSGAAAAABJRU5ErkJggg==")!)
}
