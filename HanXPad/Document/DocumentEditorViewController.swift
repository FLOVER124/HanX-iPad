import UIKit

/// HWP / HWPX / DOCX editor: paged text, the macOS ribbon (홈 · 글자 모양 ·
/// 양식 · 삽입 · 쪽 문단 · 보기), touch zoom, find & replace and the
/// software-keyboard shortcut bar.
final class DocumentEditorViewController: HanXEditorViewController, UITextViewDelegate, UIScrollViewDelegate, PageTextActions,
                                          UIFontPickerViewControllerDelegate {
    let doc: TextDocument
    private let scroll = UIScrollView()
    private var pages: PageLayoutView!
    private weak var current: PageTextView?
    private let ruler = RulerView()
    private let findBar = FindReplaceBar()
    private var rulerVisible = false
    private var stackTop: NSLayoutConstraint?

    init(document: TextDocument) {
        doc = document
        super.init(baseDocument: document)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildRibbon()

        pages = PageLayoutView(storage: doc.storage, page: doc.page)
        pages.decorations = doc.decorations()
        pages.configureTextView = { [weak self] tv in self?.configure(tv) }
        pages.textViews.forEach(configure)
        pages.textDelegate = self
        pages.onPagesChanged = { [weak self] in self?.pagesChanged() }

        scroll.delegate = self
        scroll.minimumZoomScale = 0.25
        scroll.maximumZoomScale = 4
        scroll.backgroundColor = HanXTheme.canvas
        scroll.keyboardDismissMode = .interactive
        scroll.alwaysBounceVertical = true
        scroll.addSubview(pages)

        let stack = UIStackView(arrangedSubviews: [findBar, ruler, scroll])
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            ruler.heightAnchor.constraint(equalToConstant: 26),
        ])
        ruler.isHidden = true
        findBar.isHidden = true
        findBar.editor = self
        ruler.editor = self

        if doc.storage.length == 0 { pages.textViews.first?.typingAttributes = doc.defaultTypingAttributes() }
        pages.paginate()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if !didInitialZoom, scroll.bounds.width > 0 {
            didInitialZoom = true
            let fit = min(1.4, (scroll.bounds.width - 16) / pages.bounds.width)
            scroll.zoomScale = max(scroll.minimumZoomScale, fit)
            scrollViewDidEndZooming(scroll, with: pages, atScale: scroll.zoomScale)
        }
        centerPages()
    }

    private var didInitialZoom = false

    override func didFinishPresenting() {
        super.didFinishPresenting()
        if let first = pages.textViews.first, doc.storage.length < 2 { first.becomeFirstResponder() }
    }

    private func configure(_ tv: PageTextView) {
        tv.actions = self
        tv.delegate = self
        if doc.storage.length == 0 { tv.typingAttributes = doc.defaultTypingAttributes() }
        let tap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        tap.numberOfTapsRequired = 2
        tap.cancelsTouchesInView = false
        tap.delegate = AttachmentTapDelegate.shared
        tv.addGestureRecognizer(tap)
        // Software keyboard shortcut bar (iPad): common formatting at the edges.
        let bold = UIBarButtonItem(image: UIImage(systemName: "bold"), primaryAction: UIAction { [weak self] _ in self?.command("bold", "", 0) })
        let italic = UIBarButtonItem(image: UIImage(systemName: "italic"), primaryAction: UIAction { [weak self] _ in self?.command("italic", "", 0) })
        let underline = UIBarButtonItem(image: UIImage(systemName: "underline"), primaryAction: UIAction { [weak self] _ in self?.command("underline", "", 0) })
        let table = UIBarButtonItem(image: UIImage(systemName: "tablecells"), primaryAction: UIAction { [weak self] _ in self?.command("table", "", 0) })
        let image = UIBarButtonItem(image: UIImage(systemName: "photo"), primaryAction: UIAction { [weak self] _ in self?.command("image", "", 0) })
        tv.inputAssistantItem.leadingBarButtonGroups += [UIBarButtonItemGroup(barButtonItems: [bold, italic, underline], representativeItem: nil)]
        tv.inputAssistantItem.trailingBarButtonGroups = [UIBarButtonItemGroup(barButtonItems: [table, image], representativeItem: nil)] + tv.inputAssistantItem.trailingBarButtonGroups
    }

    private var activeTextView: PageTextView { current ?? pages.textViews.first! }

    // MARK: Layout, zoom, scrolling

    private func pagesChanged() {
        let scale = scroll.zoomScale
        // The zoomed view keeps its top-left corner at the content origin.
        pages.center = CGPoint(x: pages.bounds.width * scale / 2, y: pages.bounds.height * scale / 2)
        scroll.contentSize = CGSize(width: pages.bounds.width * scale, height: pages.bounds.height * scale)
        centerPages()
        ruler.setNeedsDisplay()
    }

    private func centerPages() {
        let w = pages.bounds.width * scroll.zoomScale
        let inset = max(0, (scroll.bounds.width - w) / 2)
        if abs(scroll.contentInset.left - inset) > 0.5 {
            scroll.contentInset = UIEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { pages }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerPages(); ruler.setNeedsDisplay() }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { ruler.setNeedsDisplay() }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        pages.applyRenderingScale(scale * traitCollection.displayScale)
    }

    private func zoom(to scale: CGFloat) {
        scroll.setZoomScale(max(scroll.minimumZoomScale, min(scroll.maximumZoomScale, scale)), animated: true)
        scrollViewDidEndZooming(scroll, with: pages, atScale: scroll.zoomScale)
    }

    private func scrollToCaret(in tv: UITextView) {
        guard let pos = tv.selectedTextRange?.end else { return }
        let caret = tv.caretRect(for: pos)
        guard caret.origin.x.isFinite, caret.origin.y.isFinite else { return }
        let r = tv.convert(caret.insetBy(dx: -20, dy: -40), to: scroll)
        scroll.scrollRectToVisible(r, animated: true)
    }

    // MARK: Selection across pages

    func textViewDidBeginEditing(_ textView: UITextView) {
        if let tv = textView as? PageTextView { current = tv }
        ribbon?.refresh()
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        guard let tv = textView as? PageTextView, tv.isFirstResponder else { return }
        current = tv
        let sel = tv.selectedRange
        // After typing pushes the caret onto the next page, follow it there.
        if sel.length == 0, let target = pages.textView(forCharacterAt: sel.location), target !== tv,
           doc.storage.length > 0, !tv.hasMarkedText {
            let attrs = tv.typingAttributes
            current = target
            target.becomeFirstResponder()
            target.selectedRange = sel
            target.typingAttributes = attrs
            scrollToCaret(in: target)
        }
        ribbon?.refresh()
        ruler.setNeedsDisplay()
    }

    func textViewDidChange(_ textView: UITextView) {
        updateChrome()
        scrollToCaret(in: textView)
    }

    func setSelection(_ range: NSRange) {
        let length = doc.storage.length
        let r = NSRange(location: max(0, min(range.location, length)), length: max(0, min(range.length, length - min(range.location, length))))
        pages.paginate()
        guard let tv = pages.textView(forCharacterAt: r.location) else { return }
        if !tv.isFirstResponder { tv.becomeFirstResponder() }
        current = tv
        tv.selectedRange = r
        scrollToCaret(in: tv)
    }

    // MARK: Undoable edits

    func replace(_ range: NSRange, with new: NSAttributedString, actionName: String, select: NSRange? = nil) {
        let storage = doc.storage
        let safe = NSRange(location: min(range.location, storage.length), length: min(range.length, storage.length - min(range.location, storage.length)))
        let old = storage.attributedSubstring(from: safe)
        let previous = current?.selectedRange ?? safe
        storage.beginEditing()
        storage.replaceCharacters(in: safe, with: new)
        storage.endEditing()
        let inserted = NSRange(location: safe.location, length: new.length)
        doc.undoManager.registerUndo(withTarget: self) { target in
            target.replace(inserted, with: old, actionName: actionName, select: previous)
        }
        doc.undoManager.setActionName(actionName)
        setSelection(select ?? NSRange(location: NSMaxRange(inserted), length: 0))
        updateChrome()
    }

    private var ctx: TextBridge.Context { TextBridge.Context(images: doc.images, source: doc.sourceFormat) }

    private func chars(_ name: String, _ change: (inout CharProps) -> Void) {
        let tv = activeTextView
        let range = tv.selectedRange
        if range.length == 0 {
            var props = TextBridge.charProps(tv.typingAttributes)
            change(&props)
            var attrs = TextBridge.charAttributes(props, eastAsian: true)
            for k in paragraphLevelKeys { attrs[k] = tv.typingAttributes[k] }
            tv.typingAttributes = attrs
            ribbon?.refresh()
            return
        }
        let replacement = TextBridge.restyled(doc.storage.attributedSubstring(from: range), change)
        replace(range, with: replacement, actionName: name, select: NSRange(location: range.location, length: replacement.length))
    }

    private func para(_ name: String, _ change: (inout ParaProps) -> Void) {
        let tv = activeTextView
        let storage = doc.storage
        let sel = tv.selectedRange
        if storage.length == 0 {
            var props = TextBridge.paraProps(tv.typingAttributes)
            change(&props)
            var attrs = tv.typingAttributes
            for k in paragraphLevelKeys { attrs[k] = nil }
            for (k, v) in TextBridge.paragraphAttributes(props, mark: TextBridge.charProps(attrs), ctx: ctx) { attrs[k] = v }
            tv.typingAttributes = attrs
            return
        }
        let ns = storage.string as NSString
        let pr = ns.paragraphRange(for: NSRange(location: min(sel.location, storage.length), length: sel.length))
        let replacement = TextBridge.reparagraphed(storage.attributedSubstring(from: pr), ctx: ctx, change)
        replace(pr, with: replacement, actionName: name, select: sel)
        var attrs = activeTextView.typingAttributes
        let at = min(sel.location, max(0, storage.length - 1))
        for k in paragraphLevelKeys { attrs[k] = storage.attribute(k, at: at, effectiveRange: nil) }
        activeTextView.typingAttributes = attrs
    }

    private var currentChar: CharProps {
        let tv = activeTextView
        let storage = doc.storage
        if tv.selectedRange.length > 0, tv.selectedRange.location < storage.length {
            return TextBridge.charProps(storage.attributes(at: tv.selectedRange.location, effectiveRange: nil))
        }
        return TextBridge.charProps(tv.typingAttributes)
    }

    // MARK: Ribbon

    private func buildRibbon() {
        typealias R = RibbonView
        let fonts = FontResolver.shared.allFamilies
        let clipboard = R.Group(title: "클립보드", items: [.button("cut", "잘라내기", "scissors"), .button("copy", "복사", "doc.on.doc"), .button("paste", "붙여넣기", "doc.on.clipboard")])
        let text = R.Group(title: "글꼴", items: [.field("font", "글꼴", Array(fonts.prefix(30))), .field("size", "글자 크기", ["8", "9", "10", "11", "12", "14", "16", "18", "20", "24", "28", "32", "36", "44", "48", "60", "72"]),
                                                .toggle("bold", "굵게", "bold"), .toggle("italic", "기울임", "italic"), .toggle("underline", "밑줄", "underline")])
        installRibbon([
            .init(title: "홈", groups: [clipboard, text, .init(title: "문단", items: [
                .menu("align", "정렬", ["왼쪽 정렬", "가운데 정렬", "오른쪽 정렬", "양쪽 정렬"], symbol: "text.alignleft"),
                .menu("spacing", "줄 간격", ["줄 간격 1.0", "줄 간격 1.15", "줄 간격 1.5", "줄 간격 2.0", "줄 간격 160% (한글)"], symbol: "arrow.up.and.down.text.horizontal"),
                .button("indent", "들여쓰기", "increase.indent"), .button("outdent", "내어쓰기", "decrease.indent"),
                .menu("style", "스타일", EditorStyleNames.known, symbol: "textformat"),
            ])]),
            .init(title: "글자 모양", groups: [.init(title: "강조", items: [
                .toggle("strike", "취소선", "strikethrough"), .toggle("super", "위 첨자", "textformat.superscript"), .toggle("sub", "아래 첨자", "textformat.subscript"),
                .menu("color", "글자 색", R.colorMenu, symbol: "paintpalette"), .menu("highlight", "형광펜", ["형광펜 없음"] + R.colorMenu, symbol: "highlighter"),
                .button("clearFormat", "글자 모양 초기화", "eraser"),
            ]), .init(title: "자간 장평", items: [.field("charSpacing", "자간 (pt)", ["0", "-1", "0.5", "1", "2", "3"]), .field("widthRatio", "장평 (%)", ["100", "80", "90", "110", "120"])])]),
            .init(title: "양식", groups: [.init(title: "새 문서", items: [.menu("documentTemplate", "새 양식", DocumentTemplates.names, symbol: "doc.text")])]),
            .init(title: "삽입", groups: [.init(title: "문서 요소", items: [
                .button("table", "표", "tablecells"), .button("editTable", "표 편집", "square.and.pencil"), .button("image", "그림", "photo"),
                .button("pageBreak", "쪽 나누기", "doc.badge.plus"), .button("divider", "구분선", "minus"),
                .button("headerFooter", "머리말 꼬리말", "rectangle.topthird.inset.filled"),
                .menu("pageNumber", "쪽 번호", ["쪽 번호 없음", "아래 가운데", "아래 오른쪽", "위 오른쪽 / 전체"], symbol: "number"),
            ])]),
            .init(title: "쪽 문단", groups: [.init(title: "용지", items: [
                .button("pageSetup", "편집 용지 여백", "doc"), .menu("orientation", "용지 방향", ["세로", "가로"], symbol: "rotate.right"),
                .menu("margins", "여백", ["여백 선택…", "보통 (25.4mm)", "좁게 (12.7mm)", "넓게 (38.1mm)"], symbol: "rectangle.dashed"),
            ]), .init(title: "문단 간격", items: [
                .menu("before", "문단 앞", ["문단 앞 0pt", "문단 앞 6pt", "문단 앞 12pt", "문단 앞 18pt"], symbol: "arrow.up.to.line"),
                .menu("after", "문단 뒤", ["문단 뒤 0pt", "문단 뒤 6pt", "문단 뒤 12pt", "문단 뒤 18pt"], symbol: "arrow.down.to.line"),
            ])]),
            .init(title: "보기", groups: [.init(title: "확대 축소", items: [
                .button("zoomOut", "축소", "minus.magnifyingglass"), .button("fit", "쪽 맞춤", "arrow.up.left.and.down.right.magnifyingglass"),
                .button("zoomIn", "확대", "plus.magnifyingglass"), .toggle("ruler", "눈금자", "ruler"), .toggle("find", "찾기 바꾸기", "magnifyingglass"),
            ])]),
        ])
        ribbon?.onCommand = { [weak self] id, value, n in self?.command(id, value, n) }
        ribbon?.isOn = { [weak self] id in self?.isOn(id) ?? false }
        ribbon?.currentValue = { [weak self] id in self?.value(id) }
        ribbon?.customField = { [weak self] id, source in
            guard id == "font", let self else { return false }
            let picker = UIFontPickerViewController()
            picker.delegate = self
            self.presentPopover(picker, from: source, size: CGSize(width: 360, height: 520))
            return true
        }
    }

    private func isOn(_ id: String) -> Bool {
        let c = currentChar
        switch id {
        case "bold": return c.bold
        case "italic": return c.italic
        case "underline": return c.underline != .none
        case "strike": return c.strike
        case "super": return c.verticalAlign == .superscript
        case "sub": return c.verticalAlign == .subscript
        case "ruler": return rulerVisible
        case "find": return !findBar.isHidden
        default: return false
        }
    }

    private func value(_ id: String) -> String? {
        let c = currentChar
        switch id {
        case "font": return c.eastAsianFontName ?? c.fontName
        case "size": return SheetValue.general((c.size * 10).rounded() / 10)
        case "charSpacing": return SheetValue.general(c.spacing)
        case "widthRatio": return SheetValue.general(c.widthRatio)
        default: return nil
        }
    }

    func fontPickerViewControllerDidPickFont(_ viewController: UIFontPickerViewController) {
        guard let family = viewController.selectedFontDescriptor?.object(forKey: .family) as? String else { return }
        viewController.dismiss(animated: true)
        command("font", family, -1)
    }

    private func command(_ id: String, _ value: String, _ n: Int) {
        let source = ribbon?.control(id)
        switch id {
        case "cut": activeTextView.cut(nil)
        case "copy": activeTextView.copy(nil)
        case "paste": activeTextView.paste(nil)
        case "font": chars("글꼴") { $0.fontName = value; $0.eastAsianFontName = value }
        case "size": if let v = Double(value), v.isFinite, v > 0 { chars("글자 크기") { $0.size = min(400, v) } }
        case "bold": let on = !currentChar.bold; chars("굵게") { $0.bold = on }
        case "italic": let on = !currentChar.italic; chars("기울임") { $0.italic = on }
        case "underline": let on = currentChar.underline == .none; chars("밑줄") { $0.underline = on ? .single : .none }
        case "strike": let on = !currentChar.strike; chars("취소선") { $0.strike = on }
        case "super": let on = currentChar.verticalAlign != .superscript; chars("위 첨자") { $0.verticalAlign = on ? .superscript : .baseline }
        case "sub": let on = currentChar.verticalAlign != .subscript; chars("아래 첨자") { $0.verticalAlign = on ? .subscript : .baseline }
        case "color":
            if n >= 0 && n < Palette.colors.count { let c = Palette.colors[n]; chars("글자 색") { $0.color = c } }
            else { ColorPickerCoordinator.present(from: self, title: "글자 색", initial: currentChar.color, source: source) { [weak self] c in self?.chars("글자 색") { $0.color = c } } }
        case "highlight":
            if n == 0 { chars("형광펜") { $0.highlight = nil } }
            else if n - 1 < Palette.colors.count { let c = Palette.colors[n - 1]; chars("형광펜") { $0.highlight = c } }
            else { ColorPickerCoordinator.present(from: self, title: "형광펜", initial: currentChar.highlight, source: source) { [weak self] c in self?.chars("형광펜") { $0.highlight = c } } }
        case "clearFormat": let base = TextDocument.defaultCharProps(for: doc.sourceFormat); chars("글자 모양 초기화") { $0 = base }
        case "charSpacing": if let v = Double(value), v.isFinite, abs(v) <= 100 { chars("자간") { $0.spacing = v } }
        case "widthRatio": if let v = Double(value), v.isFinite, v >= 10, v <= 500 { chars("장평") { $0.widthRatio = v } }
        case "align":
            let a: [Alignment] = [.left, .center, .right, .justify]
            if a.indices.contains(n) { para("정렬") { $0.alignment = a[n] } }
        case "spacing":
            let s: [LineSpacing] = [.multiple(1), .multiple(1.15), .multiple(1.5), .multiple(2), .percentOfSize(160)]
            if s.indices.contains(n) { para("줄 간격") { $0.lineSpacing = s[n] } }
        case "indent", "outdent":
            let change = id == "indent" ? 18.0 : -18.0
            para("들여쓰기") { p in p.indentLeft = max(0, p.indentLeft + change); if p.indentLeft + p.firstLine < 0 { p.firstLine = -p.indentLeft } }
        case "style": applyStyle(value)
        case "before": para("문단 앞 간격") { $0.spaceBefore = Double(n * 6) }
        case "after": para("문단 뒤 간격") { $0.spaceAfter = Double(n * 6) }
        case "documentTemplate": newFromTemplate(n)
        case "table": insertTable()
        case "editTable": editTableNearCaret()
        case "image": insertImage(source: source)
        case "pageBreak": insertPageBreak()
        case "divider": insertDivider()
        case "headerFooter": editHeaderFooter()
        case "pageNumber": setPageNumbering(n)
        case "pageSetup": showPageSetup()
        case "orientation":
            var p = doc.page
            let short = min(p.width, p.height), long = max(p.width, p.height)
            p.width = n == 0 ? short : long; p.height = n == 0 ? long : short
            changePage(p)
        case "margins":
            if n > 0 { var p = doc.page; let m = [0.0, 72, 36, 108][n]; p.marginLeft = m; p.marginRight = m; p.marginTop = m; p.marginBottom = m; changePage(p) }
        case "zoomOut": zoom(to: scroll.zoomScale / 1.2)
        case "zoomIn": zoom(to: scroll.zoomScale * 1.2)
        case "fit": zoom(to: min((scroll.bounds.width - 16) / pages.bounds.width, (scroll.bounds.height - 16) / (CGFloat(doc.page.height) + PageLayoutView.gap * 2)))
        case "ruler":
            rulerVisible.toggle()
            UIView.animate(withDuration: 0.2) { self.ruler.isHidden = !self.rulerVisible }
        case "find": showFind(nil)
        default: break
        }
        ribbon?.refresh()
    }

    // PageTextActions
    func pageTextToggle(_ id: String) { command(id, "", 0) }
    func pageTextPasteImage(_ image: UIImage) {
        guard let encoded = image.normalizedOrientation().embeddableData() else { return }
        insertImageData(encoded.0, ext: encoded.1, image: image)
    }

    // MARK: Styles

    private func applyStyle(_ name: String) {
        var c = TextDocument.defaultCharProps(for: doc.sourceFormat)
        var change: (inout ParaProps) -> Void = { $0.styleName = name }
        switch name {
        case "제목": c.size = doc.sourceFormat == .docx ? 28 : 20; c.bold = true; change = { $0.styleName = name; $0.alignment = .center; $0.spaceAfter = 12 }
        case "부제목": c.size = 15; c.color = RGB(r: 89, g: 89, b: 89); change = { $0.styleName = name; $0.alignment = .center; $0.spaceAfter = 10 }
        case "제목 1": c.size = 16; c.bold = true; change = { $0.styleName = name; $0.spaceBefore = 12; $0.spaceAfter = 6 }
        case "제목 2": c.size = 13; c.bold = true; change = { $0.styleName = name; $0.spaceBefore = 10; $0.spaceAfter = 4 }
        case "제목 3": c.size = 12; c.bold = true; c.color = RGB(r: 31, g: 77, b: 120); change = { $0.styleName = name; $0.spaceBefore = 8; $0.spaceAfter = 4 }
        case "인용": c.italic = true; c.color = RGB(r: 64, g: 64, b: 64); change = { $0.styleName = name; $0.indentLeft = 36; $0.indentRight = 36 }
        case "강조": c.bold = true; c.color = RGB(r: 40, g: 100, b: 210); change = { $0.styleName = name }
        default: change = { $0.styleName = name; $0.spaceBefore = 0 }
        }
        let tv = activeTextView
        let storage = doc.storage
        guard storage.length > 0 else { return }
        let pr = (storage.string as NSString).paragraphRange(for: tv.selectedRange)
        let base = c
        var out = TextBridge.restyled(storage.attributedSubstring(from: pr)) { props in
            let keepColor = props.color != .black && name == "바탕글"
            let color = props.color
            props = base
            if keepColor { props.color = color }
        }
        out = TextBridge.reparagraphed(out, ctx: ctx, change)
        replace(pr, with: out, actionName: "스타일", select: tv.selectedRange)
    }

    // MARK: Insert

    private func insertTable() {
        promptNumbers("표 만들기", fields: [("줄 수", 3), ("칸 수", 3)]) { [weak self] values in
            guard let self, let values, values.count == 2 else { return }
            let rows = Int(values[0]), cols = Int(values[1])
            guard (1...200).contains(rows), (1...40).contains(cols) else { self.presentMessage("표를 만들 수 없습니다", "줄은 1~200, 칸은 1~40 사이로 입력하세요."); return }
            let tv = self.activeTextView
            let table = TextBridge.emptyTable(rows: rows, cols: cols, width: self.doc.page.contentWidth, source: self.doc.sourceFormat, images: self.doc.images)
            let insertion = NSMutableAttributedString()
            let storage = self.doc.storage
            let at = tv.selectedRange.location
            // A table occupies its own paragraph.
            if at > 0, at <= storage.length, (storage.string as NSString).character(at: at - 1) != 10 {
                insertion.append(NSAttributedString(string: "\n", attributes: tv.typingAttributes))
            }
            insertion.append(table)
            self.replace(tv.selectedRange, with: insertion, actionName: "표 넣기")
        }
    }

    private func insertImage(source: Any?) {
        MediaPicker.pick(.image, from: self, source: source) { [weak self] picked in
            guard let self, let picked else { return }
            self.insertImageData(picked.data, ext: picked.ext, image: picked.image ?? UIImage(data: picked.data))
        }
    }

    private func insertImageData(_ data: Data, ext: String, image: UIImage?) {
        let key = doc.nextImageKey(ext: ext)
        doc.images[key] = ImageData(name: (key as NSString).lastPathComponent, data: data)
        let size = image?.size ?? CGSize(width: 200, height: 150)
        let maxW = CGFloat(doc.page.contentWidth)
        let w = min(size.width, maxW), h = size.width > 0 ? size.height * w / size.width : size.height
        let tv = activeTextView
        let mark = TextBridge.charProps(tv.typingAttributes)
        let s = NSMutableAttributedString(attributedString: TextBridge.image(id: key, width: Double(w), height: Double(h), maxWidth: Double(maxW), mark: mark,
                                                                           ctx: ctx))
        for k in paragraphLevelKeys { if let v = tv.typingAttributes[k] { s.addAttribute(k, value: v, range: NSRange(location: 0, length: s.length)) } }
        replace(tv.selectedRange, with: s, actionName: "그림 넣기")
    }

    private func insertPageBreak() {
        let tv = activeTextView
        replace(tv.selectedRange, with: NSAttributedString(string: "\u{0C}", attributes: tv.typingAttributes), actionName: "쪽 나누기")
    }

    private func insertDivider() {
        let tv = activeTextView
        var divider = Paragraph()
        divider.markProps = TextBridge.charProps(tv.typingAttributes)
        divider.props.bottomBorder = .thin
        divider.props.alignment = .left
        let rule = TextBridge.paragraph(divider, width: doc.page.contentWidth, ctx: ctx)
        let insertion = NSMutableAttributedString(string: "\n", attributes: tv.typingAttributes)
        insertion.append(rule)
        replace(tv.selectedRange, with: insertion, actionName: "구분선")
    }

    // MARK: Tables and images (double tap)

    @objc private func doubleTapped(_ g: UITapGestureRecognizer) {
        guard let tv = g.view as? PageTextView, let index = attachmentIndex(at: g.location(in: tv), in: tv) else { return }
        let attachment = doc.storage.attribute(.attachment, at: index, effectiveRange: nil)
        if let table = attachment as? TableAttachment { editTable(table, at: index) }
        else if attachment is NSTextAttachment { editImage(at: index, in: tv, point: g.location(in: tv)) }
    }

    private func attachmentIndex(at point: CGPoint, in tv: UITextView) -> Int? {
        let lm = tv.layoutManager
        let container = tv.textContainer
        var fraction: CGFloat = 0
        let glyph = lm.glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: &fraction)
        guard glyph < lm.numberOfGlyphs else { return nil }
        let rect = lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        guard rect.insetBy(dx: -6, dy: -6).contains(point) else { return nil }
        let index = lm.characterIndexForGlyph(at: glyph)
        guard index < doc.storage.length, doc.storage.attribute(.attachment, at: index, effectiveRange: nil) != nil else { return nil }
        return index
    }

    private func editTableNearCaret() {
        let storage = doc.storage
        let sel = activeTextView.selectedRange
        for i in [sel.location, sel.location - 1, sel.location + 1] where i >= 0 && i < storage.length {
            if let t = storage.attribute(.attachment, at: i, effectiveRange: nil) as? TableAttachment { editTable(t, at: i); return }
        }
        presentMessage("표를 선택하세요", "표 바로 앞이나 뒤에 커서를 두거나, 표를 두 번 탭하세요.")
    }

    private func editTable(_ attachment: TableAttachment, at index: Int) {
        let editor = TableEditorViewController(table: attachment.table, source: doc.sourceFormat)
        editor.onDone = { [weak self] table in
            guard let self, index < self.doc.storage.length else { return }
            var attrs = self.doc.storage.attributes(at: index, effectiveRange: nil)
            let updated = TableAttachment(table: table, images: attachment.images, source: attachment.source, maxWidth: attachment.maxWidth)
            attrs[.attachment] = updated
            self.replace(NSRange(location: index, length: 1), with: NSAttributedString(string: "\u{FFFC}", attributes: attrs), actionName: "표 편집",
                         select: NSRange(location: index + 1, length: 0))
        }
        presentSheet(editor, size: CGSize(width: 900, height: 700))
    }

    private func editImage(at index: Int, in tv: UITextView, point: CGPoint) {
        guard let att = doc.storage.attribute(.attachment, at: index, effectiveRange: nil) as? NSTextAttachment else { return }
        let sheet = UIAlertController(title: "그림", message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "크기 조정…", style: .default) { [weak self] _ in
            guard let self else { return }
            let size = att.bounds.size
            self.promptNumbers("그림 크기 (pt)", fields: [("너비", Double(size.width.rounded())), ("높이", Double(size.height.rounded()))]) { values in
                guard let values, values.count == 2, values[0] > 1, values[1] > 1 else { return }
                self.resizeImage(at: index, to: CGSize(width: min(values[0], self.doc.page.contentWidth), height: min(values[1], self.doc.page.contentHeight)))
            }
        })
        sheet.addAction(UIAlertAction(title: "원래 크기", style: .default) { [weak self] _ in
            guard let self, let image = att.image else { return }
            let maxW = CGFloat(self.doc.page.contentWidth)
            let w = min(image.size.width, maxW)
            self.resizeImage(at: index, to: CGSize(width: w, height: image.size.height * w / max(1, image.size.width)))
        })
        sheet.addAction(UIAlertAction(title: "삭제", style: .destructive) { [weak self] _ in
            self?.replace(NSRange(location: index, length: 1), with: NSAttributedString(), actionName: "그림 삭제")
        })
        sheet.addAction(UIAlertAction(title: "취소", style: .cancel))
        sheet.popoverPresentationController?.sourceView = tv
        sheet.popoverPresentationController?.sourceRect = CGRect(origin: point, size: CGSize(width: 1, height: 1))
        present(sheet, animated: true)
    }

    private func resizeImage(at index: Int, to size: CGSize) {
        guard index < doc.storage.length, let old = doc.storage.attribute(.attachment, at: index, effectiveRange: nil) as? NSTextAttachment else { return }
        var attrs = doc.storage.attributes(at: index, effectiveRange: nil)
        let att = NSTextAttachment()
        att.image = old.image
        att.bounds = CGRect(origin: .zero, size: size)
        attrs[.attachment] = att
        replace(NSRange(location: index, length: 1), with: NSAttributedString(string: "\u{FFFC}", attributes: attrs), actionName: "그림 크기",
                select: NSRange(location: index + 1, length: 0))
    }

    // MARK: Header, footer, page numbers, page setup

    private func setDecorations(header: [Block]?, footer: [Block]?, actionName: String) {
        let oldHeader = doc.header, oldFooter = doc.footer
        doc.header = header
        doc.footer = footer
        pages.decorations = doc.decorations()
        doc.undoManager.registerUndo(withTarget: self) { $0.setDecorations(header: oldHeader, footer: oldFooter, actionName: actionName) }
        doc.undoManager.setActionName(actionName)
        updateChrome()
    }

    private func editHeaderFooter() {
        let editor = HeaderFooterViewController(header: doc.header, footer: doc.footer, images: doc.images, source: doc.sourceFormat, width: doc.page.contentWidth)
        editor.onDone = { [weak self] header, footer in self?.setDecorations(header: header, footer: footer, actionName: "머리말 꼬리말") }
        presentSheet(editor, size: CGSize(width: 680, height: 560))
    }

    private func setPageNumbering(_ option: Int) {
        func hasField(_ b: Block) -> Bool {
            if case .paragraph(let p) = b { return p.inlines.contains { if case .field = $0 { return true }; return false } }
            return false
        }
        var header = doc.header?.filter { !hasField($0) }
        var footer = doc.footer?.filter { !hasField($0) }
        var c = TextDocument.defaultCharProps(for: doc.sourceFormat)
        c.size = 9
        var p = Paragraph()
        p.markProps = c
        switch option {
        case 1: p.props.alignment = .center; p.inlines = [.text("- ", c), .field(.page, c), .text(" -", c)]
        case 2: p.props.alignment = .right; p.inlines = [.field(.page, c)]
        case 3: p.props.alignment = .right; p.inlines = [.field(.page, c), .text(" / ", c), .field(.pageCount, c)]
        default: break
        }
        if option == 1 || option == 2 { footer = (footer ?? []) + [.paragraph(p)] }
        if option == 3 { header = (header ?? []) + [.paragraph(p)] }
        setDecorations(header: header?.isEmpty == true ? nil : header, footer: footer?.isEmpty == true ? nil : footer, actionName: "쪽 번호")
    }

    private func changePage(_ p: PageSetup) {
        let old = doc.page
        guard p != old else { return }
        doc.page = p
        pages.page = p
        pages.decorations = doc.decorations()
        // Tables follow the new text width.
        let width = CGFloat(p.contentWidth)
        var tableRanges: [NSRange] = []
        doc.storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: doc.storage.length)) { v, r, _ in
            if let t = v as? TableAttachment { t.maxWidth = width; tableRanges.append(r) }
        }
        if !tableRanges.isEmpty {
            doc.storage.beginEditing()
            for r in tableRanges { doc.storage.edited(.editedAttributes, range: r, changeInLength: 0) }
            doc.storage.endEditing()
        }
        doc.undoManager.registerUndo(withTarget: self) { $0.changePage(old) }
        doc.undoManager.setActionName("편집 용지")
        pagesChanged()
        updateChrome()
    }

    private func showPageSetup() {
        let setup = PageSetupViewController(page: doc.page)
        setup.onDone = { [weak self] p in self?.changePage(p) }
        presentSheet(setup, size: CGSize(width: 540, height: 620))
    }

    private func newFromTemplate(_ n: Int) {
        guard (0...1).contains(n), let model = DocumentTemplates.make(n == 0 ? "letter" : "labels") else { return }
        model.source = doc.sourceFormat == .unknown ? .hwpx : doc.sourceFormat
        let ext = model.source == .docx ? "docx" : model.source == .hwp ? "hwp" : "hwpx"
        let data: Data
        switch ext {
        case "docx": data = DOCXWriter(model).write()
        case "hwp": data = HWP5Writer(model).write()
        default: data = HWPXWriter(model).write()
        }
        openGeneratedDocument(data: data, name: DocumentTemplates.names[n], ext: ext)
    }

    // MARK: Find & replace

    override func showFind(_ sender: Any?) {
        let show = findBar.isHidden
        UIView.animate(withDuration: 0.2) { self.findBar.isHidden = !show }
        if show {
            let sel = activeTextView.selectedRange
            if sel.length > 0, sel.length < 200 { findBar.query = (doc.storage.string as NSString).substring(with: sel) }
            findBar.focus()
        }
        ribbon?.refresh()
    }

    func find(_ query: String, backwards: Bool, caseSensitive: Bool) -> Bool {
        guard !query.isEmpty else { return false }
        let ns = doc.storage.string as NSString
        let sel = current?.selectedRange ?? NSRange(location: 0, length: 0)
        var options: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        var r: NSRange
        if backwards {
            options.insert(.backwards)
            r = ns.range(of: query, options: options, range: NSRange(location: 0, length: sel.location))
            if r.location == NSNotFound { r = ns.range(of: query, options: options) }
        } else {
            let start = NSMaxRange(sel)
            r = ns.range(of: query, options: options, range: NSRange(location: start, length: ns.length - start))
            if r.location == NSNotFound { r = ns.range(of: query, options: options) }
        }
        guard r.location != NSNotFound else { return false }
        setSelection(r)
        return true
    }

    func replaceCurrent(_ query: String, with text: String, caseSensitive: Bool) -> Bool {
        let ns = doc.storage.string as NSString
        let sel = current?.selectedRange ?? NSRange(location: 0, length: 0)
        if sel.length > 0, ns.substring(with: sel).compare(query, options: caseSensitive ? [] : [.caseInsensitive]) == .orderedSame {
            let attrs = doc.storage.attributes(at: sel.location, effectiveRange: nil)
            replace(sel, with: NSAttributedString(string: text, attributes: attrs), actionName: "바꾸기", select: NSRange(location: sel.location + (text as NSString).length, length: 0))
        }
        return find(query, backwards: false, caseSensitive: caseSensitive)
    }

    func replaceAll(_ query: String, with text: String, caseSensitive: Bool) -> Int {
        guard !query.isEmpty else { return 0 }
        let storage = doc.storage
        let ns = storage.string as NSString
        var ranges: [NSRange] = []
        var search = NSRange(location: 0, length: ns.length)
        while true {
            let r = ns.range(of: query, options: caseSensitive ? [] : [.caseInsensitive], range: search)
            if r.location == NSNotFound { break }
            ranges.append(r)
            search = NSRange(location: NSMaxRange(r), length: ns.length - NSMaxRange(r))
        }
        guard let first = ranges.first, let last = ranges.last else { return 0 }
        let whole = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        let out = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: whole))
        for r in ranges.reversed() {
            let local = NSRange(location: r.location - whole.location, length: r.length)
            let attrs = out.attributes(at: local.location, effectiveRange: nil)
            out.replaceCharacters(in: local, with: NSAttributedString(string: text, attributes: attrs))
        }
        replace(whole, with: out, actionName: "모두 바꾸기", select: NSRange(location: whole.location, length: 0))
        return ranges.count
    }

    // MARK: Hardware keyboard

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(title: "쪽 나누기", action: #selector(keyPageBreak), input: "\r", modifierFlags: .control),
            UIKeyCommand(title: "확대", action: #selector(keyZoomIn), input: "=", modifierFlags: .command),
            UIKeyCommand(title: "축소", action: #selector(keyZoomOut), input: "-", modifierFlags: .command),
            UIKeyCommand(title: "들여쓰기", action: #selector(keyIndent), input: "]", modifierFlags: .command),
            UIKeyCommand(title: "내어쓰기", action: #selector(keyOutdent), input: "[", modifierFlags: .command),
            UIKeyCommand(title: "다음 찾기", action: #selector(keyFindNext), input: "g", modifierFlags: .command),
        ]
    }
    @objc private func keyPageBreak() { insertPageBreak() }
    @objc private func keyZoomIn() { command("zoomIn", "", 0) }
    @objc private func keyZoomOut() { command("zoomOut", "", 0) }
    @objc private func keyIndent() { command("indent", "", 0) }
    @objc private func keyOutdent() { command("outdent", "", 0) }
    @objc private func keyFindNext() { _ = find(findBar.query, backwards: false, caseSensitive: findBar.caseSensitive) }

    override func commitPendingEdits() {
        current?.unmarkText()
    }

    // MARK: Ruler support

    /// Page frame (in ruler coordinates) and the current paragraph's indents.
    func rulerGeometry(for rulerView: UIView) -> (page: CGRect, marginLeft: CGFloat, marginRight: CGFloat, indent: CGFloat, scale: CGFloat)? {
        guard let first = pages.sheets.first else { return nil }
        let frame = first.convert(first.bounds, to: rulerView)
        var indent: CGFloat = 0
        let storage = doc.storage
        if storage.length > 0, let sel = current?.selectedRange {
            let ps = storage.attribute(.paragraphStyle, at: min(sel.location, storage.length - 1), effectiveRange: nil) as? NSParagraphStyle
            indent = ps?.headIndent ?? 0
        }
        return (frame, CGFloat(doc.page.marginLeft), CGFloat(doc.page.marginRight), indent, scroll.zoomScale)
    }
}

/// Lets the attachment double-tap run alongside UITextView's own gestures.
final class AttachmentTapDelegate: NSObject, UIGestureRecognizerDelegate {
    static let shared = AttachmentTapDelegate()
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

/// Millimetre ruler above the page (보기 › 눈금자).
final class RulerView: UIView {
    weak var editor: DocumentEditorViewController?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = HanXTheme.toolbar
        contentMode = .redraw
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let g = UIGraphicsGetCurrentContext(), let geo = editor?.rulerGeometry(for: self) else { return }
        let page = CGRect(x: geo.page.minX, y: 2, width: geo.page.width, height: bounds.height - 4)
        g.setFillColor(HanXTheme.border.cgColor)
        g.fill(page)
        let s = geo.scale
        let text = CGRect(x: page.minX + geo.marginLeft * s, y: page.minY, width: page.width - (geo.marginLeft + geo.marginRight) * s, height: page.height)
        g.setFillColor(UIColor.white.cgColor)
        g.fill(text)
        let mm = 72.0 / 25.4 * s
        g.setStrokeColor(UIColor(white: 0.45, alpha: 1).cgColor)
        g.setLineWidth(0.5)
        var i = 0
        var x = text.minX
        while x <= page.maxX {
            let h: CGFloat = i % 10 == 0 ? 8 : i % 5 == 0 ? 5 : 3
            g.move(to: CGPoint(x: x, y: page.maxY)); g.addLine(to: CGPoint(x: x, y: page.maxY - h))
            if i % 10 == 0 && i > 0 {
                ("\(i / 10)" as NSString).draw(at: CGPoint(x: x + 2, y: page.minY), withAttributes: [.font: UIFont.systemFont(ofSize: 8), .foregroundColor: UIColor.darkGray])
            }
            i += 1
            x += mm
        }
        g.strokePath()
        // Left indent marker.
        let ix = text.minX + geo.indent * s
        g.setFillColor(HanXTheme.accent.cgColor)
        g.move(to: CGPoint(x: ix - 4, y: page.maxY)); g.addLine(to: CGPoint(x: ix + 4, y: page.maxY)); g.addLine(to: CGPoint(x: ix, y: page.maxY - 6)); g.closePath(); g.fillPath()
    }
}

/// Find and replace bar (보기 › 찾기 바꾸기, ⌘F).
final class FindReplaceBar: UIView, UITextFieldDelegate {
    weak var editor: DocumentEditorViewController?
    private let findField = UITextField()
    private let replaceField = UITextField()
    private let status = UILabel()
    private let caseButton = UIButton(type: .system)
    private(set) var caseSensitive = false

    var query: String {
        get { findField.text ?? "" }
        set { findField.text = newValue }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = HanXTheme.toolbar
        for (f, p) in [(findField, "찾을 내용"), (replaceField, "바꿀 내용")] {
            f.placeholder = p
            f.borderStyle = .roundedRect
            f.clearButtonMode = .whileEditing
            f.autocorrectionType = .no
            f.autocapitalizationType = .none
            f.returnKeyType = f === findField ? .search : .done
            f.delegate = self
        }
        func button(_ title: String, _ symbol: String?, _ action: @escaping () -> Void) -> UIButton {
            var c = UIButton.Configuration.bordered()
            c.title = symbol == nil ? title : nil
            c.image = symbol.flatMap { UIImage(systemName: $0) }
            let b = UIButton(configuration: c, primaryAction: UIAction { _ in action() })
            b.accessibilityLabel = title
            return b
        }
        let prev = button("이전", "chevron.up") { [weak self] in self?.run(.previous) }
        let next = button("다음", "chevron.down") { [weak self] in self?.run(.next) }
        let replace = button("바꾸기", nil) { [weak self] in self?.run(.replace) }
        let all = button("모두 바꾸기", nil) { [weak self] in self?.run(.replaceAll) }
        caseButton.configuration = .bordered()
        caseButton.configuration?.title = "Aa"
        caseButton.accessibilityLabel = "대소문자 구분"
        caseButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.caseSensitive.toggle()
            self.caseButton.configuration = self.caseSensitive ? .filled() : .bordered()
            self.caseButton.configuration?.title = "Aa"
        }, for: .primaryActionTriggered)
        let close = button("닫기", "xmark") { [weak self] in self?.editor?.showFind(nil) }
        status.font = .systemFont(ofSize: 12)
        status.textColor = HanXTheme.secondary
        status.setContentHuggingPriority(.required, for: .horizontal)
        let stack = UIStackView(arrangedSubviews: [findField, prev, next, caseButton, replaceField, replace, all, status, close])
        stack.spacing = 8
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -12),
            findField.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
            replaceField.widthAnchor.constraint(equalTo: findField.widthAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func focus() { findField.becomeFirstResponder(); findField.selectAll(nil) }

    private enum Action { case next, previous, replace, replaceAll }

    private func run(_ action: Action) {
        guard let editor else { return }
        let q = query
        guard !q.isEmpty else { status.text = ""; return }
        switch action {
        case .next: status.text = editor.find(q, backwards: false, caseSensitive: caseSensitive) ? "" : "찾지 못함"
        case .previous: status.text = editor.find(q, backwards: true, caseSensitive: caseSensitive) ? "" : "찾지 못함"
        case .replace: status.text = editor.replaceCurrent(q, with: replaceField.text ?? "", caseSensitive: caseSensitive) ? "" : "더 없음"
        case .replaceAll:
            let n = editor.replaceAll(q, with: replaceField.text ?? "", caseSensitive: caseSensitive)
            status.text = n == 0 ? "찾지 못함" : "\(n)개 바꿈"
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === findField { run(.next) } else { run(.replace) }
        return true
    }
}
