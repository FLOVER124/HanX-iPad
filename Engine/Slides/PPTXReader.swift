import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// PresentationML reader. Resolves what PowerPoint resolves at render time:
/// placeholder geometry and text styles inherited slide → layout → master,
/// theme colours/fonts, group transforms, and layout/master decorations.
final class PPTXReader {
    private let zip: ZipReader
    private let pres = Presentation()
    private var themeColors: [String: RGB] = [:]
    private var themeFonts: [String: String] = [:]

    private struct Part {
        let path: String
        let root: XMLElement
        let rels: [String: String]
    }

    init(zip: ZipReader) { self.zip = zip }

    private func dir(_ path: String) -> String { (path as NSString).deletingLastPathComponent }

    private func normalize(_ path: String) -> String {
        var out: [Substring] = []
        for c in path.split(separator: "/") { if c == ".." { _ = out.popLast() } else if c != "." { out.append(c) } }
        return out.joined(separator: "/")
    }

    private func part(_ path: String) -> Part? {
        guard let x = zip.xml(path)?.rootElement() else { return nil }
        var rels: [String: String] = [:]
        let relPath = dir(path) + "/_rels/" + (path as NSString).lastPathComponent + ".rels"
        if let r = zip.xml(relPath)?.rootElement() {
            for e in r.children("Relationship") {
                guard let id = e.attr("Id"), let t = e.attr("Target"), e.attr("TargetMode") != "External" else { continue }
                rels[id] = t.hasPrefix("/") ? String(t.dropFirst()) : normalize(dir(path) + "/" + t)
            }
        }
        return Part(path: path, root: x, rels: rels)
    }

    private func related(_ p: Part, type suffix: String) -> Part? {
        let relPath = dir(p.path) + "/_rels/" + (p.path as NSString).lastPathComponent + ".rels"
        guard let r = zip.xml(relPath)?.rootElement() else { return nil }
        for e in r.children("Relationship") where (e.attr("Type") ?? "").hasSuffix(suffix) {
            if let id = e.attr("Id"), let path = p.rels[id] { return part(path) }
        }
        return nil
    }

    func read() throws -> Presentation {
        guard let main = part("ppt/presentation.xml") else { throw FormatError.invalid("ppt/presentation.xml 없음") }
        if let sz = main.root.child("sldSz") {
            pres.width = DrawingML.pt(sz.attrDouble("cx")); pres.height = DrawingML.pt(sz.attrDouble("cy"))
        }
        for id in main.root.child("sldIdLst")?.children("sldId") ?? [] {
            guard let rid = id.relAttr("id"), let path = main.rels[rid], let slide = part(path) else { continue }
            pres.slides.append(readSlide(slide))
        }
        return pres
    }

    // MARK: Theme

    private func loadTheme(_ master: Part) {
        guard themeColors.isEmpty, let theme = related(master, type: "/theme") else { return }
        if let scheme = theme.root.first("clrScheme") {
            for c in scheme.elementChildren {
                if let v = c.child("srgbClr")?.attr("val"), let rgb = RGB(hex: v) { themeColors[c.local] = rgb }
                else if let v = c.child("sysClr")?.attr("lastClr"), let rgb = RGB(hex: v) { themeColors[c.local] = rgb }
            }
        }
        for (kind, el) in [("mj", theme.root.first("majorFont")), ("mn", theme.root.first("minorFont"))] {
            guard let el else { continue }
            themeFonts["+\(kind)-lt"] = el.child("latin")?.attr("typeface")
            var ea = el.child("ea")?.attr("typeface") ?? ""
            if ea.isEmpty { ea = el.children("font").first { $0.attr("script") == "Hang" }?.attr("typeface") ?? "" }
            if !ea.isEmpty { themeFonts["+\(kind)-ea"] = ea }
        }
    }

    private func color(_ e: XMLElement?) -> RGB? {
        guard let e else { return nil }
        for c in e.elementChildren {
            switch c.local {
            case "srgbClr": if let rgb = RGB(hex: c.attr("val") ?? "") { return DrawingML.modify(rgb, c) }
            case "schemeClr":
                var key = c.attr("val") ?? ""
                key = ["tx1": "dk1", "bg1": "lt1", "tx2": "dk2", "bg2": "lt2"][key] ?? key
                if let rgb = themeColors[key] { return DrawingML.modify(rgb, c) }
            case "sysClr": if let rgb = RGB(hex: c.attr("lastClr") ?? "") { return DrawingML.modify(rgb, c) }
            case "prstClr":
                let named: [String: RGB] = ["black": .black, "white": RGB(r: 255, g: 255, b: 255), "red": RGB(r: 255, g: 0, b: 0),
                                            "blue": RGB(r: 0, g: 0, b: 255), "green": RGB(r: 0, g: 128, b: 0), "yellow": RGB(r: 255, g: 255, b: 0)]
                if let rgb = named[c.attr("val") ?? ""] { return DrawingML.modify(rgb, c) }
            default: break
            }
        }
        return nil
    }

    /// Fill of an spPr/bgPr/tcPr: solid, or a gradient's first stop.
    private func fill(_ pr: XMLElement?) -> (set: Bool, color: RGB?) {
        guard let pr else { return (false, nil) }
        if pr.child("noFill") != nil { return (true, nil) }
        if let s = pr.child("solidFill") { return (true, color(s)) }
        if let g = pr.child("gradFill"), let stop = g.first("gs") { return (true, color(stop)) }
        return (false, nil)
    }

    // MARK: Slides

    private struct Inherited {
        var frame: Frame?
        var bodyPr: [XMLElement] = []
        var lstStyles: [XMLElement] = []
        var spPr: [XMLElement] = []
    }

    private func placeholders(_ p: Part?) -> [(type: String, idx: String?, sp: XMLElement)] {
        guard let tree = p?.root.first("spTree") else { return [] }
        return tree.all("sp").compactMap { sp in
            guard let ph = sp.child("nvSpPr")?.child("nvPr")?.child("ph") else { return nil }
            return (ph.attr("type") ?? "body", ph.attr("idx"), sp)
        }
    }

    private func readSlide(_ slide: Part) -> Slide {
        let layout = related(slide, type: "/slideLayout")
        let master = layout.flatMap { related($0, type: "/slideMaster") }
        if let master { loadTheme(master) }
        let layoutPh = placeholders(layout), masterPh = placeholders(master)
        let txStyles = master?.root.child("txStyles")

        func inherited(type: String, idx: String?) -> Inherited {
            var inh = Inherited()
            func match(_ list: [(type: String, idx: String?, sp: XMLElement)]) -> XMLElement? {
                if let idx, let m = list.first(where: { $0.idx == idx }) { return m.sp }
                let t = type == "ctrTitle" ? ["ctrTitle", "title"] : type == "subTitle" ? ["subTitle", "body"] : [type]
                for tt in t { if let m = list.first(where: { $0.type == tt }) { return m.sp } }
                return nil
            }
            for sp in [match(masterPh), match(layoutPh)].compactMap({ $0 }) {
                if let f = xfrm(sp.child("spPr")) { inh.frame = f }
                if let b = sp.child("txBody")?.child("bodyPr") { inh.bodyPr.append(b) }
                if let l = sp.child("txBody")?.child("lstStyle") { inh.lstStyles.append(l) }
                if let s = sp.child("spPr") { inh.spPr.append(s) }
            }
            let styleName = type == "title" || type == "ctrTitle" ? "titleStyle" : (type == "body" || type == "subTitle" || type == "obj") ? "bodyStyle" : "otherStyle"
            if let st = txStyles?.child(styleName) { inh.lstStyles.insert(st, at: 0) }
            return inh
        }

        var out = Slide()
        // Background: slide → layout → master.
        for p in [slide, layout, master].compactMap({ $0 }) {
            guard let bg = p.root.first("bg") else { continue }
            if let pr = bg.child("bgPr") {
                if let blip = pr.first("blip"), let rid = blip.relAttr("embed"), let id = image(rid, p) { out.backgroundImage = id; break }
                if let gradient = pr.child("gradFill"), let line = gradient.child("lin"),
                   let angle = Double(line.attr("ang") ?? "0"), angle.isFinite, let stops = gradient.child("gsLst")?.children("gs"),
                   (2...3).contains(stops.count), stops[0].attr("pos") == "0", stops.last?.attr("pos") == "100000",
                   let start = color(stops[0]), let end = color(stops.last) {
                    if stops.count == 3, let middle = color(stops[1]),
                       let position = Int(stops[1].attr("pos") ?? ""), (1..<100000).contains(position) {
                        out.backgroundMiddle = middle; out.backgroundMiddlePosition = Double(position) / 1000
                    }
                    out.background = start; out.backgroundEnd = end; out.backgroundAngle = angle / 60000; break
                }
                let f = fill(pr); if f.set { out.background = f.color; break }
            }
            if let ref = bg.child("bgRef"), let c = color(ref) { out.background = c; break }
        }

        var nextID = 1
        func collect(_ tree: XMLElement?, from p: Part, decoration: Bool) {
            guard let tree else { return }
            for e in tree.elementChildren {
                for var s in shapes(e, part: p, transform: nil, inherited: inherited, decoration: decoration) {
                    nextID += 1
                    s.id = nextID
                    s.locked = decoration
                    out.shapes.append(s)
                }
            }
        }
        let showMaster = slide.root.attr("showMasterSp") != "0"
        if showMaster, let master, layout?.root.attr("showMasterSp") != "0" { collect(master.root.first("spTree"), from: master, decoration: true) }
        if showMaster, let layout { collect(layout.root.first("spTree"), from: layout, decoration: true) }
        collect(slide.root.first("spTree"), from: slide, decoration: false)

        out.transition = transition(slide.root.child("transition") ?? slide.root.first("transition"))
        if let timing = slide.root.child("timing") { out.animations = animations(timing, shapes: out.shapes) }

        if let notes = related(slide, type: "/notesSlide") {
            out.notes = notes.root.all("sp").filter { $0.first("ph")?.attr("type") == "body" }
                .flatMap { $0.first("txBody")?.children("p") ?? [] }
                .map { $0.all("t").compactMap(\.stringValue).joined() }.joined(separator: "\n")
        }
        return out
    }

    private func transition(_ t: XMLElement?) -> SlideTransition {
        var out = SlideTransition()
        guard let t else { return out }
        switch t.attr("spd") { case "fast": out.duration = 0.5; case "slow": out.duration = 1.5; default: out.duration = 0.75 }
        if let d = t.attrDouble("dur") { out.duration = d / 1000 }
        if let a = t.attrDouble("advTm") { out.advanceAfter = a / 1000 }
        out.advanceOnClick = t.attr("advClick") != "0" && t.attr("advClick") != "false"
        guard let kind = t.elementChildren.first(where: { $0.local != "sndAc" && $0.local != "extLst" }) else { return out }
        out.kind = TransitionKind(rawValue: kind.local) ?? (kind.local == "barn" ? .split : .fade)
        out.advanceOnClick = t.attr("advClick") != "0" && t.attr("advClick") != "false"
        out.vertical = kind.attr("orient") == "vert" || kind.attr("dir") == "vert"
        out.inward = kind.attr("dir") == "in"
        switch kind.attr("dir") { case "l": out.direction = .right; case "u": out.direction = .bottom; case "d": out.direction = .top; default: out.direction = .left }
        if kind.local == "strips" { out.direction = ["lu":AnimDirection.left,"ru":.top,"rd":.right,"ld":.bottom][kind.attr("dir") ?? "lu"] ?? .left }
        return out
    }

    /// Flattens the timing tree's effect nodes (those carrying presetClass)
    /// in document order into the slide's animation list.
    private func animations(_ timing: XMLElement, shapes: [SlideShape]) -> [SlideAnimation] {
        var out: [SlideAnimation] = []
        for ctn in timing.all("cTn") {
            guard let cls = ctn.attr("presetClass"), ["entr", "emph", "exit"].contains(cls) else { continue }
            guard let spid = ctn.first("spTgt")?.attrInt("spid") else { continue }
            let effect = AnimEffect.from(presetClass: cls, id: ctn.attrInt("presetID") ?? 10)
            var trigger = AnimTrigger(rawValue: ctn.attr("nodeType") ?? "") ?? .withPrevious
            let durations = ctn.all("cTn").compactMap { $0.attrDouble("dur") }.filter { $0 > 1 }
            let duration = (durations.max() ?? effect.defaultDuration * 1000) / 1000
            let delay = (ctn.child("stCondLst")?.child("cond")?.attrDouble("delay") ?? 0) / 1000
            let dir = AnimDirection.from(subtype: ctn.attrInt("presetSubtype") ?? 4)
            for target in shapes.filter({ $0.sourceIDs.contains(spid) }) {
                out.append(SlideAnimation(shapeID: target.id, effect: effect, trigger: trigger,
                                          duration: effect == .appear || effect == .disappear ? 0 : duration, delay: max(0, delay), direction: dir))
                trigger = .withPrevious   // remaining members of a group start together
            }
        }
        return out
    }

    private func xfrm(_ spPr: XMLElement?) -> Frame? {
        guard let x = spPr?.child("xfrm"), let off = x.child("off"), let ext = x.child("ext") else { return nil }
        return Frame(x: DrawingML.pt(off.attrDouble("x")), y: DrawingML.pt(off.attrDouble("y")),
                     w: DrawingML.pt(ext.attrDouble("cx")), h: DrawingML.pt(ext.attrDouble("cy")))
    }

    private typealias Transform = (Frame) -> Frame

    private func shapes(_ e: XMLElement, part p: Part, transform: Transform?, inherited: (String, String?) -> Inherited, decoration: Bool) -> [SlideShape] {
        let map: Transform = transform ?? { $0 }
        switch e.local {
        case "sp":
            let ph = e.child("nvSpPr")?.child("nvPr")?.child("ph")
            // Layout/master placeholders are prompts ("제목을 입력하십시오"), not content.
            if decoration && ph != nil { return [] }
            let inh = ph.map { inherited($0.attr("type") ?? "body", $0.attr("idx")) } ?? Inherited()
            var s = SlideShape()
            s.name = e.child("nvSpPr")?.child("cNvPr")?.attr("name") ?? ""
            s.sourceIDs = [e.child("nvSpPr")?.child("cNvPr")?.attrInt("id") ?? -1]
            s.placeholder = ph.map { $0.attr("type") ?? "body" }
            let spPr = e.child("spPr")
            guard let f = xfrm(spPr) ?? inh.frame else { return [] }
            s.frame = map(f)
            if let x = spPr?.child("xfrm") {
                s.rotation = (x.attrDouble("rot") ?? 0) / 60000
                s.flipH = x.attr("flipH") == "1"; s.flipV = x.attr("flipV") == "1"
            }
            let prst = spPr?.child("prstGeom")?.attr("prst") ?? (spPr?.child("custGeom") != nil ? "rect" : nil)
            s.lockAspect = e.first("spLocks")?.attr("noChangeAspect") == "1"
            switch prst {
            case "rect", "flowChartProcess", "snip1Rect": s.kind = .rect
            case "roundRect", "round2SameRect", "flowChartAlternateProcess": s.kind = .roundRect
            case "ellipse", "flowChartConnector", "donut": s.kind = .ellipse
            case "triangle", "rtTriangle": s.kind = .triangle
            case "rightArrow", "homePlate": s.kind = .rightArrow
            case "line", "straightConnector1": s.kind = .line
            default: s.kind = prst.flatMap(ShapeKind.init(rawValue:)) ?? (prst == nil ? .text : .rect)
            }
            var filled = fill(spPr)
            if !filled.set { for pr in inh.spPr.reversed() { let f = fill(pr); if f.set { filled = f; break } } }
            if !filled.set, let ref = e.child("style")?.child("fillRef"), (ref.attrInt("idx") ?? 0) > 0 { filled = (true, color(ref)) }
            s.fill = filled.color
            if let ln = spPr?.child("ln") {
                if ln.child("noFill") == nil { s.line = color(ln.child("solidFill")) ?? (ln.child("solidFill") != nil ? .black : nil) }
                if let w = ln.attrDouble("w") { s.lineWidth = DrawingML.pt(w) }
            } else if let ref = e.child("style")?.child("lnRef"), (ref.attrInt("idx") ?? 0) > 0 {
                s.line = color(ref)
            }
            if s.kind == .text && s.fill != nil { s.kind = .rect }
            if s.kind == .rect && s.fill == nil && s.line == nil { s.kind = .text }
            if let body = e.child("txBody") {
                text(body, into: &s, inherited: inh, styleColor: e.child("style")?.child("fontRef").flatMap(color), part: p)
            }
            if s.kind == .text && !s.hasText && decoration { return [] }
            return [s]
        case "pic":
            guard let f = xfrm(e.child("spPr")) else { return [] }
            let videoRel = e.first("videoFile")?.relAttr("link")
            let movieID = videoRel.flatMap { image($0, p) }
                ?? (videoRel != nil ? (e.first("media")?.relAttr("embed")).flatMap { image($0, p) } : nil)
            var poster = (e.first("blip")?.relAttr("embed")).flatMap { image($0, p) }
            if movieID != nil && poster == nil {
                pres.images[SlideMovie.posterKey] = SlideMovie.poster
                poster = SlideMovie.posterKey
            }
            guard let id = poster else { return [] }
            var s = SlideShape()
            s.kind = .image
            s.frame = map(f)
            s.imageID = id
            s.videoID = movieID
            let tx = e.child("spPr")?.child("xfrm")
            s.rotation = (tx?.attrDouble("rot") ?? 0)/60000
            s.flipH = tx?.attr("flipH") == "1"; s.flipV = tx?.attr("flipV") == "1"
            s.lockAspect = e.first("picLocks")?.attr("noChangeAspect") == "1"
            s.name = e.child("nvPicPr")?.child("cNvPr")?.attr("name") ?? "그림"
            s.sourceIDs = [e.child("nvPicPr")?.child("cNvPr")?.attrInt("id") ?? -1]
            return [s]
        case "cxnSp":
            guard let f = xfrm(e.child("spPr")) else { return [] }
            var s = SlideShape()
            s.kind = .line
            s.lockAspect=e.first("cxnSpLocks")?.attr("noChangeAspect") == "1"
            s.frame = map(f)
            s.sourceIDs = [e.child("nvCxnSpPr")?.child("cNvPr")?.attrInt("id") ?? -1]
            let x = e.child("spPr")?.child("xfrm")
            s.flipH = x?.attr("flipH") == "1"; s.flipV = x?.attr("flipV") == "1"
            s.rotation = (x?.attrDouble("rot") ?? 0)/60000
            let ln = e.child("spPr")?.child("ln")
            s.line = color(ln?.child("solidFill")) ?? e.child("style")?.child("lnRef").flatMap(color) ?? .black
            if let w = ln?.attrDouble("w") { s.lineWidth = DrawingML.pt(w) }
            return [s]
        case "grpSp":
            guard let gx = e.child("grpSpPr")?.child("xfrm"), let off = gx.child("off"), let ext = gx.child("ext") else {
                return e.elementChildren.flatMap { shapes($0, part: p, transform: transform, inherited: inherited, decoration: decoration) }
            }
            let chOff = gx.child("chOff"), chExt = gx.child("chExt")
            let ox = DrawingML.pt(off.attrDouble("x")), oy = DrawingML.pt(off.attrDouble("y"))
            let ew = DrawingML.pt(ext.attrDouble("cx")), eh = DrawingML.pt(ext.attrDouble("cy"))
            let cx = DrawingML.pt(chOff?.attrDouble("x")), cy = DrawingML.pt(chOff?.attrDouble("y"))
            let cw = DrawingML.pt(chExt?.attrDouble("cx") ?? ext.attrDouble("cx")), ch = DrawingML.pt(chExt?.attrDouble("cy") ?? ext.attrDouble("cy"))
            let sx = cw > 0 ? ew / cw : 1, sy = ch > 0 ? eh / ch : 1
            let inner: Transform = { f in map(Frame(x: ox + (f.x - cx) * sx, y: oy + (f.y - cy) * sy, w: f.w * sx, h: f.h * sy)) }
            let gid = e.child("nvGrpSpPr")?.child("cNvPr")?.attrInt("id") ?? -1
            return e.elementChildren.flatMap { shapes($0, part: p, transform: inner, inherited: inherited, decoration: decoration) }
                .map { var c = $0; c.sourceIDs.append(gid); return c }
        case "graphicFrame":
            guard let tbl = e.first("tbl"), let x = e.child("xfrm"), let off = x.child("off"), let ext = x.child("ext") else { return [] }
            var s = SlideShape()
            s.kind = .table
            s.rotation=(x.attrDouble("rot") ?? 0)/60000
            s.flipH=x.attr("flipH") == "1"; s.flipV=x.attr("flipV") == "1"
            s.lockAspect=e.first("graphicFrameLocks")?.attr("noChangeAspect") == "1"
            s.sourceIDs = [e.child("nvGraphicFramePr")?.child("cNvPr")?.attrInt("id") ?? -1]
            s.frame = map(Frame(x: DrawingML.pt(off.attrDouble("x")), y: DrawingML.pt(off.attrDouble("y")),
                                w: DrawingML.pt(ext.attrDouble("cx")), h: DrawingML.pt(ext.attrDouble("cy"))))
            var t = Table()
            t.columnWidths = tbl.child("tblGrid")?.children("gridCol").map { DrawingML.pt($0.attrDouble("w")) } ?? []
            for tr in tbl.children("tr") {
                s.tableRowHeights.append(DrawingML.pt(tr.attrDouble("h")))
                var row: [TableCell] = []
                for tc in tr.children("tc") {
                    var cell = TableCell()
                    cell.colSpan = tc.attrInt("gridSpan") ?? 1
                    cell.rowSpan = tc.attrInt("rowSpan") ?? 1
                    cell.isMergedAway = tc.attr("hMerge") == "1" || tc.attr("vMerge") == "1"
                    let pr = tc.child("tcPr")
                    cell.background = fill(pr).color
                    var inner = SlideShape()
                    if let body = tc.child("txBody") { text(body, into: &inner, inherited: Inherited(), styleColor: nil, part: p) }
                    cell.blocks = inner.paragraphs.map { .paragraph($0) }
                    if cell.blocks.isEmpty { cell.blocks = [.paragraph(Paragraph())] }
                    cell.borders = CellBorders(left: .thin, right: .thin, top: .thin, bottom: .thin)
                    switch pr?.attr("anchor") { case "ctr": cell.verticalAlign = .center; case "b": cell.verticalAlign = .bottom; default: break }
                    row.append(cell)
                }
                t.rows.append(row)
            }
            s.table = t
            return [s]
        case "AlternateContent":
            if let c = e.child("Choice") ?? e.child("Fallback") {
                return c.elementChildren.flatMap { shapes($0, part: p, transform: transform, inherited: inherited, decoration: decoration) }
            }
            return []
        default:
            return []
        }
    }

    private func image(_ rid: String, _ p: Part) -> String? {
        guard let path = p.rels[rid] else { return nil }
        if pres.images[path] == nil {
            guard let d = zip.read(path) else { return nil }
            pres.images[path] = ImageData(name: (path as NSString).lastPathComponent, data: d)
        }
        return path
    }

    // MARK: Text

    private func text(_ body: XMLElement, into s: inout SlideShape, inherited inh: Inherited, styleColor: RGB?, part p: Part) {
        let bodyPrs = inh.bodyPr + [body.child("bodyPr")].compactMap { $0 }
        for b in bodyPrs {
            switch b.attr("anchor") { case "ctr": s.anchor = .center; case "b": s.anchor = .bottom; case "t": s.anchor = .top; default: break }
            if let v = b.attrDouble("lIns") { s.insets.left = DrawingML.pt(v) }
            if let v = b.attrDouble("rIns") { s.insets.right = DrawingML.pt(v) }
            if let v = b.attrDouble("tIns") { s.insets.top = DrawingML.pt(v) }
            if let v = b.attrDouble("bIns") { s.insets.bottom = DrawingML.pt(v) }
            if b.attr("wrap") == "none" { s.wrap = false }
            if let fit = b.child("normAutofit") { s.autofitScale = (fit.attrDouble("fontScale") ?? 100000) / 100000 }
        }
        let lists = inh.lstStyles + [body.child("lstStyle")].compactMap { $0 }
        s.paragraphs = body.children("p").map { para($0, lists: lists, styleColor: styleColor) }
    }

    private func applyRun(_ r: XMLElement?, _ c: inout CharProps) {
        guard let r else { return }
        if let sz = r.attrDouble("sz") { c.size = sz / 100 }
        if let b = r.attr("b") { c.bold = b == "1" || b == "true" }
        if let i = r.attr("i") { c.italic = i == "1" || i == "true" }
        if let u = r.attr("u") { c.underline = u == "none" ? .none : u == "dbl" ? .double : .single }
        if let st = r.attr("strike") { c.strike = st != "noStrike" }
        if let base = r.attrDouble("baseline") { c.verticalAlign = base > 0 ? .superscript : base < 0 ? .subscript : .baseline }
        if let sp = r.attrDouble("spc") { c.spacing = sp / 100 }
        if let f = r.child("solidFill"), let col = color(f) { c.color = col }
        if let h = r.child("highlight"), let col = color(h) { c.highlight = col }
        if let l = r.child("latin")?.attr("typeface") { c.fontName = themeFonts[l] ?? l }
        if let e = r.child("ea")?.attr("typeface") { c.eastAsianFontName = themeFonts[e] ?? e }
    }

    private func para(_ p: XMLElement, lists: [XMLElement], styleColor: RGB?) -> Paragraph {
        let pPr = p.child("pPr")
        let lvl = pPr?.attrInt("lvl") ?? 0
        var c = CharProps()
        c.fontName = themeFonts["+mn-lt"] ?? "맑은 고딕"
        c.eastAsianFontName = themeFonts["+mn-ea"] ?? "맑은 고딕"
        c.size = 18
        if let sc = styleColor { c.color = sc }
        var props = ParaProps()
        props.alignment = .left
        props.lineSpacing = .multiple(0.9)
        var bullet: String?
        let levelPrs = lists.compactMap { $0.child("lvl\(lvl + 1)pPr") } + [pPr].compactMap { $0 }
        for lp in levelPrs {
            applyRun(lp.child("defRPr"), &c)
            switch lp.attr("algn") {
            case "ctr": props.alignment = .center
            case "r": props.alignment = .right
            case "just", "dist": props.alignment = .justify
            case "l": props.alignment = .left
            default: break
            }
            if let m = lp.attrDouble("marL") { props.indentLeft = DrawingML.pt(m) }
            if let i = lp.attrDouble("indent") { props.firstLine = DrawingML.pt(i) }
            if let v = lp.first("lnSpc")?.child("spcPct")?.attrDouble("val") { props.lineSpacing = .multiple(v / 100000) }
            if let v = lp.first("lnSpc")?.child("spcPts")?.attrDouble("val") { props.lineSpacing = .exact(v / 100) }
            if let v = lp.child("spcBef")?.child("spcPts")?.attrDouble("val") { props.spaceBefore = v / 100 }
            if let v = lp.child("spcAft")?.child("spcPts")?.attrDouble("val") { props.spaceAfter = v / 100 }
            if lp.child("buNone") != nil { bullet = nil }
            if let ch = lp.child("buChar")?.attr("char") { bullet = ch.unicodeScalars.first.map { $0.value >= 0xE000 && $0.value <= 0xF8FF ? "•" : ch } ?? "•" }
            if lp.child("buAutoNum") != nil { bullet = "#" }
        }
        var paragraph = Paragraph(props: props, inlines: [], markProps: c)
        if let end = p.child("endParaRPr") { var m = c; applyRun(end, &m); paragraph.markProps = m }
        for r in p.elementChildren {
            switch r.local {
            case "r", "fld":
                var rc = c
                applyRun(r.child("rPr"), &rc)
                let t = r.child("t")?.stringValue ?? ""
                if !t.isEmpty { paragraph.inlines.append(.text(t, rc)) }
            case "br":
                var rc = c; applyRun(r.child("rPr"), &rc)
                paragraph.inlines.append(.lineBreak(rc))
            default: break
            }
        }
        if let b = bullet, !paragraph.inlines.isEmpty { paragraph.props.listLabel = b }
        return paragraph
    }
}
