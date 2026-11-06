import UIKit
import UniformTypeIdentifiers
import PencilKit

/// PPTX editor: slide list, canvas, speaker notes and the macOS ribbon
/// (홈 · 삽입 · 디자인 · 배치 · 그림 · 전환 · 보기).
final class SlideEditorViewController: HanXEditorViewController, SlideCanvasDelegate, UICollectionViewDataSource, UICollectionViewDelegate,
                                       UICollectionViewDragDelegate, UICollectionViewDropDelegate, UIScrollViewDelegate, UITextViewDelegate,
                                       UIFontPickerViewControllerDelegate {
    static let shapePasteboardType = "org.hanx.shapes"
    static let slidePasteboardType = "org.hanx.slides"

    let doc: SlideFileDocument
    private(set) var current = 0
    private let navigator: UICollectionView
    private let scroll = UIScrollView()
    private let canvas = SlideCanvasView()
    private let notes = UITextView()
    private var textEditor: UITextView?
    private var editingShapeID: Int?
    private var observers: [NSObjectProtocol] = []
    private var thumbnails: [Int: UIImage] = [:]
    private var drawingCanvas: PKCanvasView?
    private var drawingPicker: PKToolPicker?

    init(document: SlideFileDocument) {
        doc = document
        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 14
        layout.sectionInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        navigator = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(baseDocument: document)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    var pres: Presentation { doc.pres }
    var slide: Slide { pres.slides.indices.contains(current) ? pres.slides[current] : Slide() }

    // SlideCanvasDelegate
    var canvasSlide: Slide { slide }
    var canvasPresentation: Presentation { pres }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildRibbon()
        navigator.backgroundColor = HanXTheme.toolbar
        navigator.dataSource = self
        navigator.delegate = self
        navigator.dragDelegate = self
        navigator.dropDelegate = self
        navigator.dragInteractionEnabled = true
        navigator.register(SlideThumbCell.self, forCellWithReuseIdentifier: "slide")

        scroll.delegate = self
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 4
        scroll.backgroundColor = HanXTheme.canvas
        scroll.addSubview(canvas)
        canvas.delegate = self
        canvas.backgroundColor = .white
        canvas.layer.shadowColor = UIColor.black.cgColor
        canvas.layer.shadowOpacity = 0.18
        canvas.layer.shadowRadius = 6
        canvas.onNudge = { [weak self] dx, dy in self?.nudge(dx, dy) }
        for g in canvas.gestures { scroll.panGestureRecognizer.require(toFail: g); scroll.pinchGestureRecognizer?.require(toFail: g) }

        notes.font = .systemFont(ofSize: 15)
        notes.backgroundColor = HanXTheme.paper
        notes.delegate = self
        notes.textContainerInset = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        notes.accessibilityLabel = "발표자 노트"
        let notesLabel = UILabel()
        notesLabel.text = "  발표자 노트"
        notesLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        notesLabel.textColor = HanXTheme.secondary
        notesLabel.backgroundColor = HanXTheme.toolbar

        let right = UIStackView(arrangedSubviews: [scroll, notesLabel, notes])
        right.axis = .vertical
        let row = UIStackView(arrangedSubviews: [navigator, right])
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: contentView.topAnchor),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            navigator.widthAnchor.constraint(equalToConstant: 190),
            notes.heightAnchor.constraint(equalToConstant: 92),
            notesLabel.heightAnchor.constraint(equalToConstant: 20),
        ])
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .slidesChanged, object: doc, queue: .main) { [weak self] _ in self?.reload() })
        observers.append(center.addObserver(forName: .slidesCommitEditing, object: doc, queue: .main) { [weak self] _ in self?.commitPendingEdits() })
        reload()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutCanvas()
    }

    override func didFinishPresenting() {
        super.didFinishPresenting()
        canvas.becomeFirstResponder()
    }

    private func layoutCanvas() {
        guard scroll.zoomScale == 1 else { return }
        let avail = scroll.bounds.insetBy(dx: 24, dy: 24)
        guard avail.width > 10, avail.height > 10 else { return }
        let aspect = CGFloat(pres.height / max(1, pres.width))
        var w = avail.width, h = w * aspect
        if h > avail.height { h = avail.height; w = h / aspect }
        let frame = CGRect(x: (scroll.bounds.width - w) / 2, y: (scroll.bounds.height - h) / 2, width: w, height: h).integral
        if canvas.frame != frame {
            canvas.frame = frame
            scroll.contentSize = scroll.bounds.size
            canvas.setNeedsDisplay()
            repositionTextEditor()
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { canvas }
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        canvas.contentScaleFactor = scale * traitCollection.displayScale
        canvas.setNeedsDisplay()
    }

    private func reload() {
        current = max(0, min(current, pres.slides.count - 1))
        thumbnails = [:]
        navigator.reloadData()
        if pres.slides.indices.contains(current) {
            navigator.selectItem(at: IndexPath(item: current, section: 0), animated: false, scrollPosition: [])
        }
        canvas.selectedIDs = canvas.selectedIDs.filter { id in slide.shapes.contains { $0.id == id } }
        canvas.setNeedsDisplay()
        layoutCanvas()
        if !notes.isFirstResponder { notes.text = slide.notes }
        updateChrome()
    }

    func select(slide index: Int) {
        endTextEditing()
        commitNotes()
        guard pres.slides.indices.contains(index) else { return }
        current = index
        canvas.selectedIDs = []
        canvas.setNeedsDisplay()
        notes.text = slide.notes
        navigator.selectItem(at: IndexPath(item: index, section: 0), animated: true, scrollPosition: .centeredVertically)
        ribbon?.refresh()
    }

    override func commitPendingEdits() {
        endTextEditing()
        commitNotes()
        finishDrawing()
    }

    // MARK: Edits

    func modifySlide(_ name: String, _ change: (inout Slide) -> Void) {
        let i = current
        doc.edit(name) { p in if p.slides.indices.contains(i) { change(&p.slides[i]) } }
    }

    func modifyShapes(_ name: String, ids: [Int]? = nil, _ change: (inout SlideShape) -> Void) {
        let targets = ids ?? canvas.selectedIDs
        guard !targets.isEmpty else { return }
        modifySlide(name) { s in for i in s.shapes.indices where targets.contains(s.shapes[i].id) && !s.shapes[i].locked { change(&s.shapes[i]) } }
    }

    func canvasCommit(_ name: String, shapes: [SlideShape]) {
        modifySlide(name) { s in for shape in shapes { if let i = s.shapes.firstIndex(where: { $0.id == shape.id }) { s.shapes[i] = shape } } }
    }

    private func nudge(_ dx: Double, _ dy: Double) {
        modifyShapes("이동") { $0.frame.x += dx; $0.frame.y += dy }
    }

    func canvasSelectionChanged() {
        if let id = editingShapeID, !canvas.selectedIDs.contains(id) { endTextEditing() }
        ribbon?.refresh()
    }

    private func add(_ shape: SlideShape, name: String) {
        var s = shape
        s.id = pres.nextID(slide)
        if s.name.isEmpty { s.name = "\(s.kind.title) \(s.id)" }
        modifySlide(name) { $0.shapes.append(s) }
        canvas.selectedIDs = [s.id]
    }

    private func centered(_ w: Double, _ h: Double) -> Frame {
        Frame(x: (pres.width - w) / 2, y: (pres.height - h) / 2, w: w, h: h)
    }

    // MARK: Text editing on the canvas

    func canvasBeginTextEditing(_ shapeID: Int) {
        endTextEditing()
        guard let s = slide.shapes.first(where: { $0.id == shapeID }), !s.locked else { return }
        let tv = UITextView()
        tv.backgroundColor = UIColor.white.withAlphaComponent(0.01)
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.allowsEditingTextAttributes = true
        tv.delegate = self
        tv.smartQuotesType = .no
        let paragraphs = s.paragraphs.isEmpty ? [Presentation.textParagraph("", size: 24)] : s.paragraphs
        tv.attributedText = SlideText.attributed(paragraphs)
        var typing = TextBridge.charAttributes(TextBridge.firstTextProps(paragraphs[0]), eastAsian: true)
        let ctx = TextBridge.Context(images: [:], source: .docx)
        for (k, v) in TextBridge.paragraphAttributes(paragraphs[0].props, mark: paragraphs[0].markProps, ctx: ctx) { typing[k] = v }
        tv.typingAttributes = typing
        tv.layer.borderColor = UIColor.systemBlue.withAlphaComponent(0.6).cgColor
        tv.layer.borderWidth = 1 / max(0.1, canvas.scale)
        canvas.addSubview(tv)
        textEditor = tv
        editingShapeID = shapeID
        canvas.hiddenTextID = shapeID
        repositionTextEditor()
        tv.becomeFirstResponder()
        ribbon?.refresh()
    }

    private func repositionTextEditor() {
        guard let tv = textEditor, let id = editingShapeID, let s = slide.shapes.first(where: { $0.id == id }) else { return }
        let rect = SlideRenderer.textRect(s)
        let center = ShapeGeometry.world(x: Double(rect.midX), y: Double(rect.midY), frame: s.frame, rotation: s.rotation)
        let scale = canvas.scale
        tv.transform = .identity
        tv.bounds = CGRect(origin: .zero, size: rect.size)
        tv.center = CGPoint(x: center.0 * scale, y: center.1 * scale)
        tv.transform = CGAffineTransform(rotationAngle: CGFloat(s.rotation) * .pi / 180).scaledBy(x: scale, y: scale)
        tv.contentScaleFactor = scale * scroll.zoomScale * traitCollection.displayScale
    }

    func endTextEditing() {
        guard let tv = textEditor, let id = editingShapeID else { return }
        textEditor = nil
        editingShapeID = nil
        canvas.hiddenTextID = nil
        let paragraphs = SlideText.paragraphs(tv.attributedText)
        tv.removeFromSuperview()
        let before = slide.shapes.first { $0.id == id }?.paragraphs
        let changed = before.map { old in old.map(\.plainText) != paragraphs.map(\.plainText) || !sameStyle(old, paragraphs) } ?? true
        if changed { modifyShapes("텍스트 편집", ids: [id]) { $0.paragraphs = paragraphs } }
        canvas.becomeFirstResponder()
    }

    private func sameStyle(_ a: [Paragraph], _ b: [Paragraph]) -> Bool {
        guard a.count == b.count else { return false }
        let encoder = JSONEncoder()
        return (try? encoder.encode(a)) == (try? encoder.encode(b))
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard textView === textEditor, text == "\n" else { return true }
        // Return inside a list item continues the list.
        let storage = textView.textStorage
        guard storage.length > 0 else { return true }
        let at = min(range.location, storage.length - 1)
        let para = (storage.string as NSString).paragraphRange(for: NSRange(location: at, length: 0))
        guard let label = storage.attribute(.hwListLabel, at: para.location, effectiveRange: nil) as? String else { return true }
        var markerRange = NSRange(location: para.location, length: 0)
        storage.enumerateAttribute(.hwListMarker, in: para, options: []) { v, r, stop in
            if v != nil { markerRange = r; stop.pointee = true }
        }
        let ns = storage.string as NSString
        let afterMarker = NSMaxRange(markerRange) > para.location ? NSMaxRange(markerRange) : para.location
        let rest = ns.substring(with: NSRange(location: afterMarker, length: NSMaxRange(para) - afterMarker)).trimmingCharacters(in: .whitespacesAndNewlines)
        if rest.isEmpty {
            // Return on an empty item ends the list.
            storage.beginEditing()
            if markerRange.length > 0 { storage.deleteCharacters(in: markerRange) }
            let plainRange = NSRange(location: para.location, length: max(0, para.length - markerRange.length))
            if plainRange.length > 0 {
                storage.removeAttribute(.hwListLabel, range: plainRange)
                storage.addAttribute(.paragraphStyle, value: NSParagraphStyle(), range: plainRange)
            }
            storage.endEditing()
            var typing = textView.typingAttributes
            typing[.hwListLabel] = nil
            typing[.hwListMarker] = nil
            typing[.paragraphStyle] = NSParagraphStyle()
            textView.selectedRange = NSRange(location: para.location, length: 0)
            textView.typingAttributes = typing
            return false
        }
        var number = 1
        var scan = para.location
        while scan > 0 {
            let prev = (storage.string as NSString).paragraphRange(for: NSRange(location: scan - 1, length: 0))
            guard storage.attribute(.hwListLabel, at: prev.location, effectiveRange: nil) as? String == "#" else { break }
            number += 1
            scan = prev.location
        }
        var markerAttrs = storage.attributes(at: para.location, effectiveRange: nil)
        markerAttrs[.hwListMarker] = label
        let typing = textView.typingAttributes
        let insertion = NSMutableAttributedString(string: "\n", attributes: typing)
        insertion.append(NSAttributedString(string: label == "#" ? "\(number + 1).\t" : "\(label)\t", attributes: markerAttrs))
        if let ps = markerAttrs[.paragraphStyle] { insertion.addAttribute(.paragraphStyle, value: ps, range: NSRange(location: 0, length: insertion.length)) }
        insertion.addAttribute(.hwListLabel, value: label, range: NSRange(location: 0, length: insertion.length))
        storage.replaceCharacters(in: range, with: insertion)
        textView.selectedRange = NSRange(location: range.location + insertion.length, length: 0)
        var newTyping = typing
        newTyping[.hwListLabel] = label
        if let ps = markerAttrs[.paragraphStyle] { newTyping[.paragraphStyle] = ps }
        textView.typingAttributes = newTyping
        return false
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        if textView === notes { commitNotes() }
    }

    private func commitNotes() {
        let text = notes.text ?? ""
        guard pres.slides.indices.contains(current), text != slide.notes else { return }
        modifySlide("노트") { $0.notes = text }
    }

    // MARK: Text formatting (editor selection, or every selected shape)

    private var currentChar: CharProps? {
        if let tv = textEditor {
            let r = tv.selectedRange
            if r.length > 0, r.location < tv.textStorage.length { return TextBridge.charProps(tv.textStorage.attributes(at: r.location, effectiveRange: nil)) }
            return TextBridge.charProps(tv.typingAttributes)
        }
        guard let s = canvas.selectedShapes.first, let p = s.paragraphs.first else { return nil }
        return TextBridge.firstTextProps(p)
    }

    private func changeText(_ name: String, _ change: (inout CharProps) -> Void) {
        if let tv = textEditor {
            let r = tv.selectedRange
            if r.length == 0 {
                var props = TextBridge.charProps(tv.typingAttributes)
                change(&props)
                var attrs = TextBridge.charAttributes(props, eastAsian: true)
                for k in paragraphLevelKeys { attrs[k] = tv.typingAttributes[k] }
                tv.typingAttributes = attrs
            } else {
                let replaced = TextBridge.restyled(tv.textStorage.attributedSubstring(from: r), change)
                tv.textStorage.replaceCharacters(in: r, with: replaced)
                tv.selectedRange = NSRange(location: r.location, length: replaced.length)
            }
            ribbon?.refresh()
            return
        }
        func apply(_ p: inout Paragraph) {
            change(&p.markProps)
            p.inlines = p.inlines.map {
                switch $0 {
                case .text(let t, var c): change(&c); return .text(t, c)
                case .tab(var c): change(&c); return .tab(c)
                case .lineBreak(var c): change(&c); return .lineBreak(c)
                case .field(let k, var c): change(&c); return .field(k, c)
                default: return $0
                }
            }
        }
        modifyShapes(name) { s in
            for i in s.paragraphs.indices { apply(&s.paragraphs[i]) }
            if var t = s.table {
                for r in t.rows.indices { for c in t.rows[r].indices {
                    t.rows[r][c].blocks = t.rows[r][c].blocks.map { b in if case .paragraph(var p) = b { apply(&p); return .paragraph(p) }; return b }
                } }
                s.table = t
            }
        }
    }

    private func changeParagraphs(_ name: String, rebuildEditor: Bool = false, _ change: (inout ParaProps) -> Void) {
        if let tv = textEditor, !rebuildEditor {
            let storage = tv.textStorage
            guard storage.length > 0 else { return }
            let sel = tv.selectedRange
            let pr = (storage.string as NSString).paragraphRange(for: sel)
            let replaced = TextBridge.reparagraphed(storage.attributedSubstring(from: pr), ctx: TextBridge.Context(images: [:], source: .docx), change)
            storage.replaceCharacters(in: pr, with: replaced)
            tv.selectedRange = sel
            return
        }
        let editing = editingShapeID
        endTextEditing()
        modifyShapes(name) { s in for i in s.paragraphs.indices { change(&s.paragraphs[i].props) } }
        if let editing { canvasBeginTextEditing(editing) }
    }

    // MARK: Ribbon

    private func buildRibbon() {
        typealias R = RibbonView
        let fonts = FontResolver.shared.allFamilies
        let clipboard = R.Group(title: "클립보드", items: [.button("cut", "잘라내기", "scissors"), .button("copy", "복사", "doc.on.doc"), .button("paste", "붙여넣기", "doc.on.clipboard")])
        let text = R.Group(title: "글꼴", items: [.field("font", "글꼴", Array(fonts.prefix(30))), .field("size", "글자 크기", ["18", "12", "14", "16", "20", "24", "28", "32", "36", "44", "48", "60", "72"]),
                                                .toggle("bold", "굵게", "bold"), .toggle("italic", "기울임", "italic"), .toggle("underline", "밑줄", "underline")])
        installRibbon([
            .init(title: "홈", groups: [clipboard, text, .init(title: "문단", items: [
                .button("left", "왼쪽", "text.alignleft"), .button("center", "가운데", "text.aligncenter"), .button("right", "오른쪽", "text.alignright"),
                .menu("bullets", "글머리", ["글머리 없음", "• 글머리표", "1. 번호"], symbol: "list.bullet"),
                .menu("spacing", "줄 간격", ["줄 간격 1.0", "줄 간격 1.15", "줄 간격 1.5", "줄 간격 2.0"], symbol: "arrow.up.and.down.text.horizontal"),
            ]), .init(title: "글자 색", items: [
                .menu("textColor", "글자 색", R.colorMenu, symbol: "paintpalette"), .menu("highlight", "형광펜", ["형광펜 없음"] + R.colorMenu, symbol: "highlighter"),
                .toggle("strike", "취소선", "strikethrough"),
            ])]),
            .init(title: "삽입", groups: [.init(title: "슬라이드", items: [
                .button("new", "새 슬라이드", "plus.rectangle"), .button("duplicateSlide", "슬라이드 복제", "rectangle.on.rectangle"), .button("deleteSlide", "슬라이드 삭제", "trash"),
            ]), .init(title: "개체", items: [
                .button("textBox", "텍스트 상자", "character.textbox"),
                .menu("shape", "도형", ShapeKind.allCases.filter { ![.image, .table, .line, .text].contains($0) }.map(\.title), symbol: "square.on.circle"),
                .button("image", "그림", "photo"), .button("video", "동영상", "film"), .button("table", "표", "tablecells"),
                .button("editTable", "표 편집", "square.and.pencil"), .button("line", "선", "line.diagonal"), .button("draw", "펜으로 그리기", "pencil.tip.crop.circle"),
            ])]),
            .init(title: "디자인", groups: [.init(title: "슬라이드 배경", items: [
                .menu("backgroundColor", "배경색", R.colorMenu, symbol: "paintbrush"), .menu("backgroundDesign", "배경 디자인", ["바다", "새벽", "숲"], symbol: "sparkles"),
                .button("backgroundCustom", "직접 설정", "slider.horizontal.3"), .button("backgroundPicture", "배경 그림", "photo"), .button("backgroundAll", "모두 적용", "rectangle.stack"),
            ]), .init(title: "슬라이드 크기", items: [.menu("slideSize", "슬라이드 크기", ["와이드스크린 (16:9)", "표준 (4:3)"], symbol: "aspectratio")])]),
            .init(title: "배치", groups: [.init(title: "크기와 회전", items: [
                .menu("rotate", "회전", ["회전 선택…", "오른쪽 90°", "왼쪽 90°", "180°", "회전 초기화", "좌우 뒤집기", "상하 뒤집기"], symbol: "rotate.right"),
                .toggle("aspect", "비율 고정", "lock.rectangle"), .menu("scale", "크기 비율", ["크기 선택…", "50%", "75%", "125%", "150%", "200%"], symbol: "arrow.up.left.and.arrow.down.right"),
                .button("geometry", "크기 위치", "ruler"),
            ]), .init(title: "정렬과 순서", items: [
                .menu("align", "맞춤", ["맞춤 선택…", "왼쪽 맞춤", "가운데 맞춤", "오른쪽 맞춤", "위쪽 맞춤", "중간 맞춤", "아래쪽 맞춤", "가로 간격 같게", "세로 간격 같게"], symbol: "align.horizontal.center"),
                .button("front", "맨 앞으로", "square.2.layers.3d.top.filled"), .button("back", "맨 뒤로", "square.2.layers.3d.bottom.filled"), .button("duplicate", "복제", "plus.square.on.square"),
            ]), .init(title: "도형 서식", items: [
                .menu("fill", "채우기", ["채우기 없음"] + R.colorMenu, symbol: "paintbrush.pointed"), .menu("lineColor", "윤곽선", ["윤곽선 없음"] + R.colorMenu, symbol: "square"),
                .menu("lineWidth", "선 굵기", ["0.5 pt", "1 pt", "2 pt", "3 pt", "4.5 pt", "6 pt"], symbol: "lineweight"),
            ])]),
            .init(title: "그림", groups: [.init(title: "그림 편집", items: [
                .button("imageCrop", "자르기", "crop"), .button("imageAdjustments", "그림 보정", "slider.horizontal.3"),
                .button("imageBackground", "배경 제거", "person.crop.rectangle"), .button("restoreImage", "원본 복원", "arrow.uturn.backward"),
            ])]),
            .init(title: "전환", groups: [.init(title: "화면 전환", items: [
                .menu("transition", "전환 효과", TransitionKind.allCases.map(\.title), symbol: "rectangle.portrait.on.rectangle.portrait.angled"),
                .field("duration", "전환 시간 (초)", ["0.7", "0.3", "0.5", "1.0", "1.5", "2.0", "3.0"]), .button("preview", "미리 보기", "play.fill"),
                .button("applyAll", "모두 적용", "rectangle.stack"), .button("transitionOptions", "효과 넘김 설정", "slider.horizontal.3"),
            ]), .init(title: "애니메이션", items: [.button("animations", "애니메이션 창", "sparkles.rectangle.stack"), .button("show", "현재부터 재생", "play.rectangle")])]),
            .init(title: "보기", groups: [.init(title: "선택", items: [.button("selectAll", "모두 선택", "checkmark.rectangle.stack"), .button("delete", "개체 삭제", "trash")]),
                                       .init(title: "슬라이드 쇼", items: [.button("showAll", "처음부터", "play.rectangle.fill"), .button("show", "현재부터", "play.fill")])]),
        ])
        ribbon?.onCommand = { [weak self] id, value, n in self?.command(id, value, n) }
        ribbon?.isOn = { [weak self] id in
            guard let self else { return false }
            let c = self.currentChar
            switch id {
            case "bold": return c?.bold ?? false
            case "italic": return c?.italic ?? false
            case "underline": return (c?.underline ?? .none) != .none
            case "strike": return c?.strike ?? false
            case "aspect": return self.canvas.selectedShapes.first?.lockAspect ?? false
            default: return false
            }
        }
        ribbon?.currentValue = { [weak self] id in
            guard let self else { return nil }
            switch id {
            case "font": return self.currentChar.map { $0.eastAsianFontName ?? $0.fontName }
            case "size": return self.currentChar.map { SheetValue.general(($0.size * 10).rounded() / 10) }
            case "duration": return SheetValue.general(self.slide.transition.duration)
            default: return nil
            }
        }
        ribbon?.isEnabled = { [weak self] id in
            guard let self else { return false }
            let selected = self.canvas.selectedShapes
            let image = selected.count == 1 && selected[0].kind == .image && selected[0].videoID == nil
            switch id {
            case "imageCrop", "imageAdjustments", "imageBackground": return image
            case "restoreImage": return image && self.doc.canRestoreImage(selected.first?.imageID)
            case "editTable": return selected.count == 1 && selected[0].kind == .table
            case "rotate", "aspect", "scale", "geometry", "front", "back", "duplicate", "fill", "lineColor", "lineWidth", "delete": return !selected.isEmpty
            case "align": return !selected.isEmpty
            case "deleteSlide": return self.pres.slides.count > 1
            default: return true
            }
        }
        ribbon?.customField = { [weak self] id, source in
            guard id == "font", let self else { return false }
            let picker = UIFontPickerViewController()
            picker.delegate = self
            self.presentPopover(picker, from: source, size: CGSize(width: 360, height: 520))
            return true
        }
    }

    func fontPickerViewControllerDidPickFont(_ viewController: UIFontPickerViewController) {
        guard let family = viewController.selectedFontDescriptor?.object(forKey: .family) as? String else { return }
        viewController.dismiss(animated: true)
        command("font", family, -1)
    }

    private func command(_ id: String, _ value: String, _ n: Int) {
        let source = ribbon?.control(id)
        if !["font", "size", "bold", "italic", "underline", "strike", "textColor", "highlight", "left", "center", "right", "spacing", "cut", "copy", "paste"].contains(id) {
            endTextEditing()
        }
        switch id {
        case "cut": if let tv = textEditor { tv.cut(nil) } else { canvasCopy(cut: true) }
        case "copy": if let tv = textEditor { tv.copy(nil) } else { canvasCopy(cut: false) }
        case "paste": if let tv = textEditor { tv.paste(nil) } else { canvasPaste() }
        case "font": changeText("글꼴") { $0.fontName = value; $0.eastAsianFontName = value }
        case "size": if let v = Double(value), v.isFinite, v > 0 { changeText("글자 크기") { $0.size = min(400, v) } }
        case "bold": let v = !(currentChar?.bold ?? false); changeText("굵게") { $0.bold = v }
        case "italic": let v = !(currentChar?.italic ?? false); changeText("기울임") { $0.italic = v }
        case "underline": let v = (currentChar?.underline ?? .none) == .none; changeText("밑줄") { $0.underline = v ? .single : .none }
        case "strike": let v = !(currentChar?.strike ?? false); changeText("취소선") { $0.strike = v }
        case "textColor":
            if n >= 0 && n < Palette.colors.count { let c = Palette.colors[n]; changeText("글자 색") { $0.color = c } }
            else { ColorPickerCoordinator.present(from: self, title: "글자 색", initial: currentChar?.color, source: source) { [weak self] c in self?.changeText("글자 색") { $0.color = c } } }
        case "highlight":
            if n == 0 { changeText("형광펜") { $0.highlight = nil } }
            else if n - 1 < Palette.colors.count { let c = Palette.colors[n - 1]; changeText("형광펜") { $0.highlight = c } }
            else { ColorPickerCoordinator.present(from: self, title: "형광펜", initial: currentChar?.highlight, source: source) { [weak self] c in self?.changeText("형광펜") { $0.highlight = c } } }
        case "left", "center", "right":
            let a: Alignment = id == "left" ? .left : id == "center" ? .center : .right
            changeParagraphs("정렬") { $0.alignment = a }
        case "spacing":
            let m = [1, 1.15, 1.5, 2.0][max(0, min(3, n))]
            changeParagraphs("줄 간격") { $0.lineSpacing = .multiple(m) }
        case "bullets":
            let labels: [String?] = [nil, "•", "#"]
            let label = labels[max(0, min(2, n))]
            changeParagraphs("글머리", rebuildEditor: true) { $0.listLabel = label; $0.indentLeft = label == nil ? 0 : 27; $0.firstLine = label == nil ? 0 : -27 }
        case "new": newSlide()
        case "duplicateSlide": duplicateSlides([current])
        case "deleteSlide": deleteSlides([current])
        case "textBox":
            var s = SlideShape(kind: .text, frame: centered(pres.width * 0.4, 60))
            s.paragraphs = [Presentation.textParagraph("", size: 24)]
            add(s, name: "텍스트 상자")
            if let id = canvas.selectedIDs.first { canvasBeginTextEditing(id) }
        case "shape":
            let kinds = ShapeKind.allCases.filter { ![.image, .table, .line, .text].contains($0) }
            guard kinds.indices.contains(n) else { return }
            var s = SlideShape(kind: kinds[n], frame: centered(220, 160))
            s.fill = RGB(r: 68, g: 114, b: 196)
            s.line = RGB(r: 47, g: 82, b: 143)
            s.lineWidth = 1
            s.anchor = .center
            s.paragraphs = [Presentation.textParagraph("", size: 18, align: .center, color: .white)]
            add(s, name: kinds[n].title)
        case "image": insertImage(source: source)
        case "video": insertVideo(source: source)
        case "table": insertTable()
        case "editTable": if let s = canvas.selectedShapes.first, s.kind == .table { canvasEditTable(s.id) }
        case "line":
            var s = SlideShape(kind: .line, frame: Frame(x: pres.width / 2 - 120, y: pres.height / 2, w: 240, h: 0))
            s.line = .black
            s.lineWidth = 2
            add(s, name: "선")
        case "draw": beginDrawing()
        case "geometry": showInspector(source: source)
        case "aspect": let v = !(canvas.selectedShapes.first?.lockAspect ?? false); modifyShapes("비율 고정") { $0.lockAspect = v }
        case "scale":
            if n > 0 {
                let k = [1.0, 0.5, 0.75, 1.25, 1.5, 2][n]
                modifyShapes("크기 비율") { s in
                    let c = (s.frame.x + s.frame.w / 2, s.frame.y + s.frame.h / 2)
                    s.frame.w *= k; s.frame.h *= k
                    s.frame.x = c.0 - s.frame.w / 2; s.frame.y = c.1 - s.frame.h / 2
                }
            }
        case "rotate":
            modifyShapes("회전 뒤집기") { s in
                switch n {
                case 1: s.rotation += 90
                case 2: s.rotation -= 90
                case 3: s.rotation += 180
                case 4: s.rotation = 0
                case 5: s.flipH.toggle()
                case 6: s.flipV.toggle()
                default: break
                }
                s.rotation = (s.rotation.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
            }
        case "align": arrangeSelection(n)
        case "front", "back":
            let ids = canvas.selectedIDs
            modifySlide(id == "front" ? "맨 앞으로" : "맨 뒤로") { sl in
                let chosen = sl.shapes.filter { ids.contains($0.id) }
                sl.shapes.removeAll { ids.contains($0.id) }
                if id == "front" { sl.shapes += chosen } else { let at = sl.shapes.prefix { $0.locked }.count; sl.shapes.insert(contentsOf: chosen, at: at) }
            }
        case "duplicate": canvasDuplicate()
        case "fill":
            if n == 0 { modifyShapes("채우기") { $0.fill = nil } }
            else if n - 1 < Palette.colors.count { let c = Palette.colors[n - 1]; modifyShapes("채우기") { $0.fill = c } }
            else { ColorPickerCoordinator.present(from: self, title: "채우기", initial: canvas.selectedShapes.first?.fill, source: source) { [weak self] c in self?.modifyShapes("채우기") { $0.fill = c } } }
        case "lineColor":
            if n == 0 { modifyShapes("윤곽선") { $0.line = nil } }
            else if n - 1 < Palette.colors.count { let c = Palette.colors[n - 1]; modifyShapes("윤곽선") { $0.line = c } }
            else { ColorPickerCoordinator.present(from: self, title: "윤곽선", initial: canvas.selectedShapes.first?.line, source: source) { [weak self] c in self?.modifyShapes("윤곽선") { $0.line = c } } }
        case "lineWidth":
            let w = [0.5, 1, 2, 3, 4.5, 6][max(0, min(5, n))]
            modifyShapes("선 굵기") { $0.lineWidth = w; if $0.line == nil { $0.line = .black } }
        case "backgroundColor":
            if n >= 0 && n < Palette.colors.count {
                let c = Palette.colors[n]
                modifySlide("배경색") { $0.background = c; $0.backgroundEnd = nil; $0.backgroundImage = nil }
            } else {
                ColorPickerCoordinator.present(from: self, title: "배경색", initial: slide.background, source: source) { [weak self] c in
                    self?.modifySlide("배경색") { $0.background = c; $0.backgroundEnd = nil; $0.backgroundImage = nil }
                }
            }
        case "backgroundDesign":
            let designs = [("204680", "80D3E9"), ("553F75", "FFB38D"), ("135B54", "ACE2A3")]
            guard designs.indices.contains(n) else { return }
            modifySlide("배경 디자인") {
                $0.background = RGB(hex: designs[n].0); $0.backgroundEnd = RGB(hex: designs[n].1); $0.backgroundAngle = 0
                $0.backgroundMiddle = nil; $0.backgroundMiddlePosition = nil; $0.backgroundImage = nil
            }
        case "backgroundCustom":
            let editor = BackgroundEditorViewController(slide: slide) { [weak self] result in
                self?.modifySlide("배경 직접 설정") { $0.copyBackground(from: result) }
            }
            presentSheet(editor, size: CGSize(width: 520, height: 560))
        case "backgroundPicture":
            MediaPicker.pick(.image, from: self, source: source) { [weak self] picked in
                guard let self, let picked else { return }
                let key = self.doc.addImage(picked.data, ext: picked.ext)
                self.modifySlide("배경 그림") { $0.backgroundImage = key }
            }
        case "backgroundAll":
            let source = slide
            doc.edit("모든 슬라이드에 배경 적용") { p in for i in p.slides.indices { p.slides[i].copyBackground(from: source) } }
        case "slideSize":
            let height = n == 1 ? 720.0 : 540.0
            let width = 960.0
            guard pres.height != height || pres.width != width else { return }
            let sx = width / pres.width, sy = height / pres.height
            doc.edit("슬라이드 크기") { p in
                p.width = width; p.height = height
                for i in p.slides.indices { for j in p.slides[i].shapes.indices {
                    p.slides[i].shapes[j].frame.x *= sx; p.slides[i].shapes[j].frame.w *= sx
                    p.slides[i].shapes[j].frame.y *= sy; p.slides[i].shapes[j].frame.h *= sy
                } }
            }
            canvas.frame = .zero
            layoutCanvas()
        case "transition":
            let kind = TransitionKind.allCases[max(0, min(TransitionKind.allCases.count - 1, n))]
            modifySlide("화면 전환") { $0.transition.kind = kind }
            previewTransition()
        case "duration": if let d = Double(value), d.isFinite, d > 0 { modifySlide("전환 시간") { $0.transition.duration = min(60, d) } }
        case "preview": previewTransition()
        case "applyAll": let t = slide.transition; doc.edit("모두 적용") { p in for i in p.slides.indices { p.slides[i].transition = t } }
        case "transitionOptions":
            let editor = TransitionOptionsViewController(transition: slide.transition) { [weak self] t in self?.modifySlide("효과 넘김 설정") { $0.transition = t } }
            presentSheet(editor, size: CGSize(width: 480, height: 520))
        case "animations": showAnimations(source: source)
        case "show": play(from: current)
        case "showAll": play(from: 0)
        case "selectAll": canvas.selectAll(nil)
        case "delete": canvasDelete()
        case "imageCrop": cropImage()
        case "imageAdjustments": adjustImage()
        case "imageBackground": removeBackground()
        case "restoreImage": if let s = canvas.selectedShapes.first { doc.restoreImage(slide: current, shapeID: s.id) }
        default: break
        }
        ribbon?.refresh()
    }

    private func arrangeSelection(_ mode: Int) {
        let ids = canvas.selectedIDs
        let chosen = slide.shapes.filter { ids.contains($0.id) }
        guard mode > 0, !chosen.isEmpty else { return }
        let boxes = chosen.map(ShapeGeometry.bounds)
        let minX = boxes.map(\.x).min()!, minY = boxes.map(\.y).min()!, maxX = boxes.map(\.maxX).max()!, maxY = boxes.map(\.maxY).max()!
        let target = chosen.count == 1 ? Frame(x: 0, y: 0, w: pres.width, h: pres.height) : Frame(x: minX, y: minY, w: maxX - minX, h: maxY - minY)
        if mode < 7 {
            modifySlide("맞춤") { sl in
                for i in sl.shapes.indices where ids.contains(sl.shapes[i].id) {
                    let b = ShapeGeometry.bounds(sl.shapes[i])
                    switch mode {
                    case 1: sl.shapes[i].frame.x += target.x - b.x
                    case 2: sl.shapes[i].frame.x += target.x + target.w / 2 - b.x - b.w / 2
                    case 3: sl.shapes[i].frame.x += target.maxX - b.maxX
                    case 4: sl.shapes[i].frame.y += target.y - b.y
                    case 5: sl.shapes[i].frame.y += target.y + target.h / 2 - b.y - b.h / 2
                    case 6: sl.shapes[i].frame.y += target.maxY - b.maxY
                    default: break
                    }
                }
            }
        } else if chosen.count >= 3 {
            let horizontal = mode == 7
            let sorted = chosen.sorted { let a = ShapeGeometry.bounds($0), b = ShapeGeometry.bounds($1); return horizontal ? a.x < b.x : a.y < b.y }
            let total = boxes.reduce(0) { $0 + (horizontal ? $1.w : $1.h) }
            let gap = ((horizontal ? target.w : target.h) - total) / Double(chosen.count - 1)
            var pos = horizontal ? target.x : target.y
            modifySlide("간격 같게") { sl in
                for s in sorted {
                    let b = ShapeGeometry.bounds(s)
                    if let i = sl.shapes.firstIndex(where: { $0.id == s.id }) {
                        if horizontal { sl.shapes[i].frame.x += pos - b.x } else { sl.shapes[i].frame.y += pos - b.y }
                    }
                    pos += (horizontal ? b.w : b.h) + gap
                }
            }
        } else {
            presentMessage("개체를 3개 이상 선택하세요", "간격을 같게 하려면 개체 3개 이상이 필요합니다.")
        }
    }

    // MARK: Slides

    private func newSlide() {
        var s = pres.contentSlide()
        s.copyBackground(from: slide)
        let at = current + 1
        doc.edit("새 슬라이드") { p in p.slides.insert(s, at: min(at, p.slides.count)) }
        select(slide: at)
    }

    private func duplicateSlides(_ indices: [Int]) {
        let sorted = indices.sorted()
        guard let last = sorted.last else { return }
        let copies = sorted.compactMap { pres.slides.indices.contains($0) ? pres.slides[$0] : nil }
        doc.edit("슬라이드 복제") { p in p.slides.insert(contentsOf: copies, at: min(last + 1, p.slides.count)) }
        select(slide: last + 1)
    }

    private func deleteSlides(_ indices: [Int]) {
        guard pres.slides.count > indices.count else { presentMessage("슬라이드를 삭제할 수 없습니다", "슬라이드가 하나 이상 남아야 합니다."); return }
        doc.edit("슬라이드 삭제") { p in for i in indices.sorted(by: >) where p.slides.indices.contains(i) { p.slides.remove(at: i) } }
        select(slide: max(0, min(current, pres.slides.count - 1)))
    }

    private func copySlides(_ indices: [Int]) {
        let sub = Presentation()
        sub.width = pres.width; sub.height = pres.height
        sub.slides = indices.sorted().compactMap { pres.slides.indices.contains($0) ? pres.slides[$0] : nil }
        sub.images = pres.images
        if let data = try? SlideClipboard.encode(sub) {
            UIPasteboard.general.setItems([[SlideEditorViewController.slidePasteboardType: data]], options: [.localOnly: true])
        }
    }

    private func pasteSlides(after index: Int) {
        guard let data = UIPasteboard.general.data(forPasteboardType: SlideEditorViewController.slidePasteboardType),
              let incoming = SlideClipboard.decode(data) else { return }
        let (slides, media) = remapped(incoming)
        doc.edit("슬라이드 붙여넣기") { p in
            for (k, v) in media { p.images[k] = v }
            p.slides.insert(contentsOf: slides, at: min(index + 1, p.slides.count))
        }
        select(slide: index + 1)
    }

    /// Gives pasted media fresh keys so they never replace existing pictures.
    private func remapped(_ incoming: Presentation) -> ([Slide], [String: ImageData]) {
        var ids: [String: String] = [:]
        var media: [String: ImageData] = [:]
        for (k, v) in incoming.images {
            if let existing = pres.images[k], existing.data == v.data { ids[k] = k; continue }
            let ext = (k as NSString).pathExtension.isEmpty ? "png" : (k as NSString).pathExtension
            let nk = "media/\(UUID().uuidString).\(ext)"
            ids[k] = nk
            media[nk] = v
        }
        return (SlideClipboard.remappingMedia(incoming.slides, ids: ids), media)
    }

    // MARK: Shapes clipboard (SlideCanvasDelegate)

    func canvasCopy(cut: Bool) {
        let chosen = canvas.selectedShapes
        guard !chosen.isEmpty else { return }
        let sub = Presentation()
        sub.width = pres.width; sub.height = pres.height
        var s = Slide()
        s.shapes = chosen
        sub.slides = [s]
        sub.images = pres.images
        guard let data = try? SlideClipboard.encode(sub) else { return }
        var item: [String: Any] = [SlideEditorViewController.shapePasteboardType: data]
        let text = chosen.flatMap { $0.paragraphs.map(\.plainText) }.joined(separator: "\n")
        if !text.isEmpty { item[UTType.utf8PlainText.identifier] = text }
        UIPasteboard.general.setItems([item])
        if cut { canvasDelete() }
    }

    func canvasPaste() {
        let board = UIPasteboard.general
        if let data = board.data(forPasteboardType: SlideEditorViewController.shapePasteboardType), let incoming = SlideClipboard.decode(data),
           let first = incoming.slides.first {
            let (slides, media) = remapped(incoming)
            var next = pres.nextID(slide)
            let existing = Set(slide.shapes.map(\.id))
            var added: [SlideShape] = []
            for var s in slides.first?.shapes ?? first.shapes {
                if existing.contains(s.id) { s.frame.x += 16; s.frame.y += 16 }
                s.id = next; next += 1
                s.locked = false
                added.append(s)
            }
            doc.edit("붙여넣기") { p in
                for (k, v) in media { p.images[k] = v }
                p.slides[current].shapes += added
            }
            canvas.selectedIDs = added.map(\.id)
        } else if board.hasImages, let image = board.image, let encoded = image.normalizedOrientation().embeddableData() {
            insertPicture(encoded.0, ext: encoded.1, size: image.size)
        } else if let text = board.string, !text.isEmpty {
            var s = SlideShape(kind: .text, frame: centered(pres.width * 0.5, 80))
            s.paragraphs = text.components(separatedBy: "\n").map { Presentation.textParagraph($0, size: 24) }
            add(s, name: "붙여넣기")
        }
    }

    func canvasDelete() {
        let ids = canvas.selectedIDs
        guard !ids.isEmpty else { return }
        modifySlide("개체 삭제") { sl in
            sl.shapes.removeAll { ids.contains($0.id) && !$0.locked }
            sl.animations.removeAll { ids.contains($0.shapeID) }
        }
        canvas.selectedIDs = []
    }

    func canvasDuplicate() {
        let chosen = canvas.selectedShapes
        guard !chosen.isEmpty else { return }
        var next = pres.nextID(slide)
        let copies: [SlideShape] = chosen.map { var s = $0; s.id = next; next += 1; s.frame.x += 16; s.frame.y += 16; return s }
        modifySlide("복제") { $0.shapes += copies }
        canvas.selectedIDs = copies.map(\.id)
    }

    func canvasMenu(for shapeID: Int?) -> UIMenu? {
        guard shapeID != nil else {
            return UIMenu(children: [
                UIAction(title: "붙여넣기", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in self?.canvasPaste() },
                UIAction(title: "모두 선택", image: UIImage(systemName: "checkmark.rectangle.stack")) { [weak self] _ in self?.canvas.selectAll(nil) },
            ])
        }
        return UIMenu(children: [
            UIMenu(options: .displayInline, children: [
                UIAction(title: "잘라내기", image: UIImage(systemName: "scissors")) { [weak self] _ in self?.canvasCopy(cut: true) },
                UIAction(title: "복사", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in self?.canvasCopy(cut: false) },
                UIAction(title: "붙여넣기", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in self?.canvasPaste() },
                UIAction(title: "복제", image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in self?.canvasDuplicate() },
            ]),
            UIAction(title: "텍스트 편집", image: UIImage(systemName: "character.cursor.ibeam")) { [weak self] _ in if let id = shapeID { self?.canvasBeginTextEditing(id) } },
            UIAction(title: "맨 앞으로", image: UIImage(systemName: "square.2.layers.3d.top.filled")) { [weak self] _ in self?.command("front", "", 0) },
            UIAction(title: "맨 뒤로", image: UIImage(systemName: "square.2.layers.3d.bottom.filled")) { [weak self] _ in self?.command("back", "", 0) },
            UIAction(title: "크기와 위치…", image: UIImage(systemName: "ruler")) { [weak self] _ in self?.command("geometry", "", 0) },
            UIAction(title: "애니메이션…", image: UIImage(systemName: "sparkles")) { [weak self] _ in self?.command("animations", "", 0) },
            UIAction(title: "삭제", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in self?.canvasDelete() },
        ])
    }

    // MARK: Insert media and tables

    private func insertImage(source: Any?) {
        MediaPicker.pick(.image, from: self, source: source) { [weak self] picked in
            guard let self, let picked else { return }
            self.insertPicture(picked.data, ext: picked.ext, size: picked.image?.size ?? CGSize(width: 400, height: 300))
        }
    }

    private func insertPicture(_ data: Data, ext: String, size: CGSize) {
        let key = doc.addImage(data, ext: ext)
        let maxW = pres.width * 0.6, maxH = pres.height * 0.6
        let k = min(1, min(maxW / max(1, Double(size.width)), maxH / max(1, Double(size.height))))
        var s = SlideShape(kind: .image, frame: centered(Double(size.width) * k, Double(size.height) * k))
        s.imageID = key
        s.lockAspect = true
        add(s, name: "그림 넣기")
    }

    private func insertVideo(source: Any?) {
        MediaPicker.pick(.movie, from: self, source: source) { [weak self] picked in
            guard let self, let picked else { return }
            let video = self.doc.addImage(picked.data, ext: picked.ext)
            if self.pres.images[SlideMovie.posterKey] == nil { self.pres.images[SlideMovie.posterKey] = SlideMovie.poster }
            var s = SlideShape(kind: .image, frame: self.centered(480, 270))
            s.imageID = SlideMovie.posterKey
            s.videoID = video
            s.lockAspect = true
            self.add(s, name: "동영상 넣기")
        }
    }

    private func insertTable() {
        promptNumbers("표 만들기", fields: [("줄 수", 3), ("칸 수", 3)]) { [weak self] v in
            guard let self, let v, v.count == 2 else { return }
            let rows = Int(v[0]), cols = Int(v[1])
            guard (1...50).contains(rows), (1...20).contains(cols) else { self.presentMessage("표를 만들 수 없습니다", "줄은 1~50, 칸은 1~20 사이로 입력하세요."); return }
            let width = self.pres.width * 0.8
            var t = Table()
            t.columnWidths = Array(repeating: width / Double(cols), count: cols)
            t.rows = (0..<rows).map { _ in (0..<cols).map { _ in TableCell(blocks: [.paragraph(Presentation.textParagraph("", size: 16))]) } }
            var s = SlideShape(kind: .table, frame: self.centered(width, Double(rows) * 40))
            s.table = t
            s.tableRowHeights = Array(repeating: 40, count: rows)
            self.add(s, name: "표 넣기")
        }
    }

    func canvasEditTable(_ shapeID: Int) {
        guard let s = slide.shapes.first(where: { $0.id == shapeID }), let table = s.table else { return }
        let editor = TableEditorViewController(table: table, source: .docx)
        editor.onDone = { [weak self] t in
            self?.modifyShapes("표 편집", ids: [shapeID]) { shape in
                let old = shape.tableRowHeights
                let average = old.isEmpty ? shape.frame.h / Double(max(1, t.rows.count)) : old.reduce(0, +) / Double(old.count)
                shape.tableRowHeights = (0..<t.rows.count).map { $0 < old.count ? old[$0] : average }
                shape.frame.h = max(shape.frame.h, shape.tableRowHeights.reduce(0, +) * shape.frame.h / max(1, old.reduce(0, +)))
                shape.table = t
            }
        }
        presentSheet(editor, size: CGSize(width: 900, height: 700))
    }

    // MARK: Pen drawing → picture

    private func beginDrawing() {
        guard drawingCanvas == nil else { finishDrawing(); return }
        let ink = PKCanvasView(frame: canvas.bounds)
        ink.backgroundColor = .clear
        ink.isOpaque = false
        ink.drawingPolicy = .anyInput
        ink.isScrollEnabled = false
        canvas.addSubview(ink)
        drawingCanvas = ink
        let picker = drawingPicker ?? PKToolPicker()
        drawingPicker = picker
        picker.setVisible(true, forFirstResponder: ink)
        picker.addObserver(ink)
        ink.becomeFirstResponder()
        let done = UIBarButtonItem(title: "그리기 완료", image: UIImage(systemName: "checkmark.circle"), primaryAction: UIAction { [weak self] _ in self?.finishDrawing() })
        navigationItem.rightBarButtonItems = (navigationItem.rightBarButtonItems ?? []) + [done]
        drawingDoneItem = done
    }
    private var drawingDoneItem: UIBarButtonItem?

    private func finishDrawing() {
        guard let ink = drawingCanvas else { return }
        drawingCanvas = nil
        drawingPicker?.setVisible(false, forFirstResponder: ink)
        drawingPicker?.removeObserver(ink)
        if let item = drawingDoneItem { navigationItem.rightBarButtonItems?.removeAll { $0 === item } }
        drawingDoneItem = nil
        let drawing = ink.drawing
        ink.removeFromSuperview()
        canvas.becomeFirstResponder()
        guard !drawing.strokes.isEmpty else { return }
        let bounds = drawing.bounds.insetBy(dx: -4, dy: -4).intersection(canvas.bounds)
        guard bounds.width > 2, bounds.height > 2 else { return }
        let image = drawing.image(from: bounds, scale: max(2, 3 / max(0.1, canvas.scale)))
        guard let png = image.pngData() else { return }
        let key = doc.addImage(png, ext: "png")
        let s = canvas.scale
        var shape = SlideShape(kind: .image, frame: Frame(x: Double(bounds.minX / s), y: Double(bounds.minY / s), w: Double(bounds.width / s), h: Double(bounds.height / s)))
        shape.imageID = key
        shape.name = "그림 (펜)"
        add(shape, name: "펜으로 그리기")
    }

    // MARK: Picture editing

    private var selectedPicture: SlideShape? {
        let s = canvas.selectedShapes
        guard s.count == 1, s[0].kind == .image, s[0].videoID == nil, !s[0].locked, s[0].imageID != nil else { return nil }
        return s[0]
    }

    private func cropImage() {
        guard let shape = selectedPicture, let id = shape.imageID, let image = pres.images[id] else { presentMessage("그림을 선택해 주세요", "자를 그림 하나를 선택하세요."); return }
        let index = current
        let editor = ImageCropViewController(data: image.data) { [weak self] png, region in
            guard let self else { return }
            if !self.doc.replaceImage(slide: index, shapeID: shape.id, expectedImageID: id, png: png, actionName: "그림 자르기", crop: region) {
                self.presentMessage("그림이 변경되었습니다", "다시 선택한 뒤 자르세요.")
            }
        }
        presentSheet(editor, size: CGSize(width: 760, height: 680))
    }

    private func adjustImage() {
        guard let shape = selectedPicture, let id = shape.imageID, let image = pres.images[id] else { presentMessage("그림을 선택해 주세요", "보정할 그림 하나를 선택하세요."); return }
        let index = current
        let editor = ImageAdjustmentsViewController(data: image.data) { [weak self] png in
            guard let self else { return }
            self.doc.replaceImage(slide: index, shapeID: shape.id, expectedImageID: id, png: png, actionName: "그림 보정")
        }
        presentSheet(editor, size: CGSize(width: 760, height: 720))
    }

    private func removeBackground() {
        guard let shape = selectedPicture, let id = shape.imageID, let image = pres.images[id] else { presentMessage("그림을 선택해 주세요", "배경을 제거할 그림 하나를 선택하세요."); return }
        let index = current
        let editor = BackgroundRemovalViewController(data: image.data) { [weak self] png in
            guard let self else { return }
            self.doc.replaceImage(slide: index, shapeID: shape.id, expectedImageID: id, png: png, actionName: "그림 배경 제거")
        }
        presentSheet(editor, size: CGSize(width: 760, height: 720))
    }

    // MARK: Inspector, animations, transitions, show

    private func showInspector(source: Any?) {
        guard let s = canvas.selectedShapes.first else { return }
        let inspector = ShapeInspectorViewController(shape: s) { [weak self] updated in
            self?.modifyShapes("크기 위치", ids: [s.id]) { $0 = updated }
        }
        presentPopover(UINavigationController(rootViewController: inspector), from: source, size: CGSize(width: 380, height: 560))
    }

    private func showAnimations(source: Any?) {
        let pane = AnimationPaneViewController(slide: slide, selected: canvas.selectedIDs) { [weak self] animations in
            self?.modifySlide("애니메이션") { $0.animations = animations }
        } onPlay: { [weak self] in
            guard let self else { return }
            self.play(from: self.current)
        }
        presentPopover(UINavigationController(rootViewController: pane), from: source, size: CGSize(width: 420, height: 600))
    }

    private func previewTransition() {
        guard pres.slides.indices.contains(current) else { return }
        let width = canvas.bounds.width
        guard width > 10 else { return }
        let to = SlideRenderer.thumbnail(slide, pres, width: width)
        let from = current > 0 ? SlideRenderer.thumbnail(pres.slides[current - 1], pres, width: width)
                               : UIGraphicsImageRenderer(size: to.size).image { ctx in UIColor.black.setFill(); ctx.fill(CGRect(origin: .zero, size: to.size)) }
        let stage = UIView(frame: canvas.bounds)
        stage.clipsToBounds = true
        canvas.addSubview(stage)
        TransitionPlayer.run(slide.transition, from: from, to: to, in: stage) { stage.removeFromSuperview() }
    }

    private func play(from index: Int) {
        commitPendingEdits()
        let show = SlideShowViewController(presentation: pres, start: index)
        show.modalPresentationStyle = .fullScreen
        present(show, animated: true)
    }

    // MARK: Navigator

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { pres.slides.count }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        CGSize(width: 150, height: 150 * pres.height / pres.width + 18)
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "slide", for: indexPath) as! SlideThumbCell
        let i = indexPath.item
        cell.number.text = "\(i + 1)" + (pres.slides[i].transition.kind == .none ? "" : "  ✦")
        if let image = thumbnails[i] { cell.image.image = image }
        else {
            let image = SlideRenderer.thumbnail(pres.slides[i], pres, width: 300)
            thumbnails[i] = image
            cell.image.image = image
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) { select(slide: indexPath.item) }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
        guard let i = indexPaths.first?.item else { return nil }
        let items = indexPaths.map(\.item)
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            UIMenu(children: [
                UIAction(title: "새 슬라이드", image: UIImage(systemName: "plus.rectangle")) { _ in self?.select(slide: i); self?.newSlide() },
                UIAction(title: "슬라이드 복제", image: UIImage(systemName: "rectangle.on.rectangle")) { _ in self?.duplicateSlides(items) },
                UIAction(title: "복사", image: UIImage(systemName: "doc.on.doc")) { _ in self?.copySlides(items) },
                UIAction(title: "붙여넣기", image: UIImage(systemName: "doc.on.clipboard")) { _ in self?.pasteSlides(after: i) },
                UIAction(title: "여기부터 재생", image: UIImage(systemName: "play.fill")) { _ in self?.play(from: i) },
                UIAction(title: "슬라이드 삭제", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in self?.deleteSlides(items) },
            ])
        })
    }

    func collectionView(_ collectionView: UICollectionView, itemsForBeginning session: UIDragSession, at indexPath: IndexPath) -> [UIDragItem] {
        let item = UIDragItem(itemProvider: NSItemProvider())
        item.localObject = indexPath.item
        return [item]
    }

    func collectionView(_ collectionView: UICollectionView, dropSessionDidUpdate session: UIDropSession, withDestinationIndexPath destinationIndexPath: IndexPath?) -> UICollectionViewDropProposal {
        session.localDragSession != nil ? UICollectionViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath) : UICollectionViewDropProposal(operation: .forbidden)
    }

    func collectionView(_ collectionView: UICollectionView, performDropWith coordinator: UICollectionViewDropCoordinator) {
        guard let from = coordinator.items.first?.dragItem.localObject as? Int, let dest = coordinator.destinationIndexPath?.item else { return }
        let to = max(0, min(pres.slides.count - 1, dest))
        guard from != to else { return }
        doc.edit("슬라이드 이동") { p in let s = p.slides.remove(at: from); p.slides.insert(s, at: to) }
        select(slide: to)
    }

    // MARK: Keyboard

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(title: "복제", action: #selector(keyDuplicate), input: "d", modifierFlags: .command),
            UIKeyCommand(title: "새 슬라이드", action: #selector(keyNewSlide), input: "m", modifierFlags: [.command, .shift]),
            UIKeyCommand(title: "슬라이드 쇼", action: #selector(keyPlay), input: "\r", modifierFlags: [.command, .alternate]),
            UIKeyCommand(title: "이전 슬라이드", action: #selector(keyPrevious), input: UIKeyCommand.inputPageUp, modifierFlags: []),
            UIKeyCommand(title: "다음 슬라이드", action: #selector(keyNext), input: UIKeyCommand.inputPageDown, modifierFlags: []),
            UIKeyCommand(title: "굵게", action: #selector(keyBold), input: "b", modifierFlags: .command),
            UIKeyCommand(title: "기울임", action: #selector(keyItalic), input: "i", modifierFlags: .command),
            UIKeyCommand(title: "밑줄", action: #selector(keyUnderline), input: "u", modifierFlags: .command),
        ]
    }
    @objc private func keyDuplicate() { canvasDuplicate() }
    @objc private func keyNewSlide() { newSlide() }
    @objc private func keyPlay() { play(from: current) }
    @objc private func keyPrevious() { select(slide: current - 1) }
    @objc private func keyNext() { select(slide: current + 1) }
    @objc private func keyBold() { command("bold", "", 0) }
    @objc private func keyItalic() { command("italic", "", 0) }
    @objc private func keyUnderline() { command("underline", "", 0) }
}

extension SlideEditorViewController: UICollectionViewDelegateFlowLayout {}

final class SlideThumbCell: UICollectionViewCell {
    let image = UIImageView()
    let number = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        image.contentMode = .scaleAspectFit
        image.backgroundColor = .white
        image.layer.borderWidth = 1
        image.layer.borderColor = HanXTheme.border.cgColor
        image.layer.cornerRadius = 3
        image.clipsToBounds = true
        number.font = .systemFont(ofSize: 11)
        number.textColor = HanXTheme.secondary
        let stack = UIStackView(arrangedSubviews: [image, number])
        stack.axis = .vertical
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor), stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor), stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            number.heightAnchor.constraint(equalToConstant: 14),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isSelected: Bool {
        didSet {
            image.layer.borderColor = (isSelected ? HanXTheme.accent : HanXTheme.border).cgColor
            image.layer.borderWidth = isSelected ? 3 : 1
        }
    }
}
