import UIKit
import PDFKit
import PencilKit

/// PDF editor: 읽기 (PDFKit reader with system find), 개체 편집 (select, move,
/// resize, rotate, recolour, edit text, replace images, delete, add text /
/// images / shapes, OCR, 문서로 편집) and 펜 (Apple Pencil markup baked into
/// the page). A page sidebar rotates, duplicates, inserts, deletes and
/// reorders pages.
final class PDFEditorViewController: HanXEditorViewController, UIScrollViewDelegate, UICollectionViewDataSource, UICollectionViewDelegate,
                                     UICollectionViewDragDelegate, UICollectionViewDropDelegate, UITextViewDelegate {
    enum Mode: Int { case read, edit, pen }

    let doc: PDFFileDocument
    private var mode: Mode = .edit
    private var pageIndex = 0
    private let modes = UISegmentedControl(items: ["읽기", "개체 편집", "펜"])
    private let sidebar: UICollectionView
    private let reader = PDFView()
    private let scroll = UIScrollView()
    private let canvas = PDFPageCanvas()
    private let status = UILabel()
    private let findBar = UIView()
    private let findField = UITextField()
    private let findCount = UILabel()
    private var inkCanvas: PKCanvasView?
    private var toolPicker: PKToolPicker?
    private var inlineEditor: UITextView?
    private var editingObject: PDFPageObject?
    private var matches: [(page: Int, rect: CGRect)] = []
    private var matchIndex = -1
    private var showDetails = false
    private var thumbnailCache: [Int: UIImage] = [:]
    private var thumbnailRevision = -1
    private var observer: NSObjectProtocol?

    init(document: PDFFileDocument) {
        doc = document
        let layout = UICollectionViewFlowLayout()
        layout.itemSize = CGSize(width: 116, height: 150)
        layout.minimumLineSpacing = 12
        layout.sectionInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        sidebar = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(baseDocument: document)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    override func extraBarItems() -> [UIBarButtonItem] {
        modes.selectedSegmentIndex = Mode.edit.rawValue
        modes.addAction(UIAction { [weak self] _ in self?.setMode(Mode(rawValue: self?.modes.selectedSegmentIndex ?? 1) ?? .edit) }, for: .valueChanged)
        return [UIBarButtonItem(customView: modes)]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildRibbon()

        sidebar.backgroundColor = HanXTheme.toolbar
        sidebar.dataSource = self
        sidebar.delegate = self
        sidebar.dragDelegate = self
        sidebar.dropDelegate = self
        sidebar.dragInteractionEnabled = true
        sidebar.register(PDFThumbnailCell.self, forCellWithReuseIdentifier: "page")

        reader.autoScales = true
        reader.displayMode = .singlePageContinuous
        reader.displayDirection = .vertical
        reader.isFindInteractionEnabled = true
        reader.backgroundColor = HanXTheme.canvas

        scroll.delegate = self
        scroll.minimumZoomScale = 0.5
        scroll.maximumZoomScale = 6
        scroll.backgroundColor = HanXTheme.canvas
        scroll.addSubview(canvas)
        scroll.panGestureRecognizer.require(toFail: canvas.panGesture)
        canvas.onSelectionChanged = { [weak self] in self?.selectionChanged() }
        canvas.onTransform = { [weak self] from, to in self?.applyEdit(.transform(page: self?.pageIndex ?? 0, from: from, to: to, quarterTurns: 0)) }
        canvas.onEditText = { [weak self] o in self?.beginTextEdit(o) }
        canvas.onDelete = { [weak self] in self?.command("delete", "", 0) }
        canvas.onNudge = { [weak self] dx, dy in self?.nudge(dx, dy) }
        canvas.onCopy = { [weak self] in self?.copySelectedText() }
        canvas.addInteraction(UIContextMenuInteraction(delegate: self))

        status.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        status.textColor = HanXTheme.secondary
        status.textAlignment = .center
        let prev = UIButton(type: .system), next = UIButton(type: .system)
        prev.setImage(UIImage(systemName: "chevron.left"), for: .normal)
        next.setImage(UIImage(systemName: "chevron.right"), for: .normal)
        prev.addAction(UIAction { [weak self] _ in self?.go(to: (self?.pageIndex ?? 0) - 1) }, for: .primaryActionTriggered)
        next.addAction(UIAction { [weak self] _ in self?.go(to: (self?.pageIndex ?? 0) + 1) }, for: .primaryActionTriggered)
        let footer = UIStackView(arrangedSubviews: [UIView(), prev, status, next, UIView()])
        footer.spacing = 12
        footer.backgroundColor = HanXTheme.toolbar
        footer.isLayoutMarginsRelativeArrangement = true
        footer.layoutMargins = UIEdgeInsets(top: 4, left: 12, bottom: 4, right: 12)

        buildFindBar()

        let main = UIView()
        for v in [reader, scroll] {
            v.translatesAutoresizingMaskIntoConstraints = false
            main.addSubview(v)
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: main.topAnchor), v.bottomAnchor.constraint(equalTo: main.bottomAnchor),
                v.leadingAnchor.constraint(equalTo: main.leadingAnchor), v.trailingAnchor.constraint(equalTo: main.trailingAnchor),
            ])
        }
        let column = UIStackView(arrangedSubviews: [findBar, main, footer])
        column.axis = .vertical
        let row = UIStackView(arrangedSubviews: [sidebar, column])
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: contentView.topAnchor),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 140),
            footer.heightAnchor.constraint(equalToConstant: 40),
        ])
        findBar.isHidden = true

        observer = NotificationCenter.default.addObserver(forName: .pdfDocumentChanged, object: doc, queue: .main) { [weak self] _ in self?.documentChanged() }
    }

    override func didFinishPresenting() {
        super.didFinishPresenting()
        if doc.isLocked { askPassword() } else { documentChanged() }
        setMode(.edit)
    }

    private func askPassword() {
        promptText("암호로 보호된 PDF", message: "PDF를 열려면 암호를 입력하세요. 편집해 저장한 사본에는 암호가 걸리지 않습니다.", placeholder: "암호") { [weak self] value in
            guard let self else { return }
            guard let value, self.doc.unlock(value) else {
                if value != nil { self.askPassword() } else { self.closeDocument(nil) }
                return
            }
            self.documentChanged()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if mode == .edit, abs(lastLayoutWidth - scroll.bounds.width) > 1 {
            lastLayoutWidth = scroll.bounds.width
            layoutCanvas(fit: fitMode)
        }
        centerCanvas()
    }
    private var lastLayoutWidth: CGFloat = 0

    // MARK: Ribbon

    private func buildRibbon() {
        installRibbon([
            .init(title: "편집", groups: [
                .init(title: "변환", items: [.button("documentMode", "문서로 편집", "doc.text")]),
                .init(title: "추가", items: [.button("addText", "텍스트 추가", "character.textbox"), .button("addImage", "이미지 추가", "photo"), .button("addRect", "도형 추가", "square")]),
                .init(title: "선택한 개체", items: [
                    .button("editText", "텍스트 수정", "pencil"), .button("replaceImage", "이미지 교체", "photo.on.rectangle"), .button("delete", "삭제", "trash"),
                    .button("geometry", "크기와 위치", "ruler"), .button("rotateLeft", "↶ 90°", "rotate.left"), .button("rotateRight", "↷ 90°", "rotate.right"),
                    .menu("fill", "채우기", RibbonView.colorMenu, symbol: "paintbrush"),
                ]),
                .init(title: "글자", items: [.toggle("find", "찾기", "magnifyingglass"), .button("ocr", "문자 인식", "text.viewfinder")]),
            ]),
            .init(title: "페이지", groups: [
                .init(title: "페이지", items: [
                    .button("pageLeft", "왼쪽으로 회전", "rotate.left"), .button("pageRight", "오른쪽으로 회전", "rotate.right"),
                    .button("pageDuplicate", "복제", "plus.square.on.square"), .button("pageBlank", "빈 페이지", "doc.badge.plus"),
                    .button("pageInsert", "PDF 삽입", "doc.on.doc"), .button("pageDelete", "페이지 삭제", "trash"),
                ]),
            ]),
            .init(title: "보기", groups: [
                .init(title: "확대", items: [.menu("zoom", "확대", ["페이지 맞춤", "너비 맞춤", "75%", "100%", "150%", "200%"], symbol: "plus.magnifyingglass")]),
                .init(title: "개체", items: [
                    .menu("objectType", "개체 종류", ["모든 개체", "텍스트", "이미지", "도형"], symbol: "line.3.horizontal.decrease.circle"),
                    .toggle("details", "세부 선 조각 보기", "scribble"), .button("objects", "개체 목록", "list.bullet.rectangle"),
                ]),
            ]),
        ])
        ribbon?.onCommand = { [weak self] id, value, n in self?.command(id, value, n) }
        ribbon?.isOn = { [weak self] id in
            guard let self else { return false }
            switch id {
            case "find": return !self.findBar.isHidden
            case "details": return self.showDetails
            default: return false
            }
        }
        ribbon?.isEnabled = { [weak self] id in
            guard let self else { return false }
            let selected = self.canvas.selectedObjects
            switch id {
            case "editText": return self.mode == .edit && selected.count == 1 && selected[0].kind == .text
            case "replaceImage": return self.mode == .edit && selected.count == 1 && selected[0].kind == .image
            case "delete", "geometry", "rotateLeft", "rotateRight", "fill": return self.mode == .edit && !selected.isEmpty
            case "pageDelete": return (self.doc.pdf?.pageCount ?? 0) > 1
            default: return !self.doc.isLocked
            }
        }
    }

    private func command(_ id: String, _ value: String, _ n: Int) {
        let source = ribbon?.control(id)
        commitTextEdit()
        switch id {
        case "documentMode": convertToDocument()
        case "addText": addText()
        case "addImage":
            MediaPicker.pick(.image, from: self, source: source) { [weak self] picked in
                guard let self, let picked else { return }
                let size = picked.image?.size ?? CGSize(width: 300, height: 200)
                let box = self.canvas.pageBox
                let w = min(box.width * 0.5, size.width), h = size.height * w / max(1, size.width)
                let c = self.visibleCenter()
                self.applyEdit(.addImage(page: self.pageIndex, rect: CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h), data: picked.data))
            }
        case "addRect":
            let c = visibleCenter()
            applyEdit(.addRect(page: pageIndex, rect: CGRect(x: c.x - 75, y: c.y - 50, width: 150, height: 100),
                             fill: RGB(r: 220, g: 232, b: 248), stroke: RGB(r: 50, g: 102, b: 168), lineWidth: 1))
        case "editText": if let o = canvas.selectedObjects.first, o.kind == .text { beginTextEdit(o) }
        case "replaceImage":
            guard let o = canvas.selectedObjects.first, o.kind == .image else { return }
            MediaPicker.pick(.image, from: self, source: source) { [weak self] picked in
                guard let self, let picked else { return }
                self.applyEdit(.replaceImage(page: self.pageIndex, rect: o.bounds, data: picked.data))
            }
        case "delete":
            let rects = canvas.selectedObjects.map(\.bounds)
            if !rects.isEmpty { applyEdit(.delete(page: pageIndex, rects: rects)) }
        case "geometry": showGeometry(source: source)
        case "rotateLeft", "rotateRight":
            guard let r = canvas.selectionBounds else { return }
            let turned = CGRect(x: r.midX - r.height / 2, y: r.midY - r.width / 2, width: r.height, height: r.width)
            applyEdit(.transform(page: pageIndex, from: r, to: turned, quarterTurns: id == "rotateLeft" ? 1 : 3))
        case "fill":
            guard let r = canvas.selectionBounds else { return }
            if n < Palette.colors.count { applyEdit(.recolor(page: pageIndex, rect: r, color: Palette.colors[n])) }
            else { ColorPickerCoordinator.present(from: self, title: "채우기", initial: nil, source: source) { [weak self] c in
                guard let self else { return }
                self.applyEdit(.recolor(page: self.pageIndex, rect: r, color: c))
            } }
        case "find": showFind(nil)
        case "ocr": runOCR()
        case "pageLeft": applyEdit(.rotatePage(page: pageIndex, degrees: -90))
        case "pageRight": applyEdit(.rotatePage(page: pageIndex, degrees: 90))
        case "pageDuplicate": applyEdit(.duplicatePage(page: pageIndex)); go(to: pageIndex + 1)
        case "pageBlank":
            let size = doc.pdf?.page(at: pageIndex)?.bounds(for: .mediaBox).size ?? CGSize(width: 595, height: 842)
            applyEdit(.insertBlankPage(at: pageIndex + 1, size: size)); go(to: pageIndex + 1)
        case "pageInsert": insertPDF()
        case "pageDelete":
            confirm("페이지를 삭제할까요?", message: "\(pageIndex + 1)페이지를 삭제합니다. 실행 취소로 되돌릴 수 있습니다.", action: "삭제", destructive: true) { [weak self] in
                guard let self else { return }
                self.applyEdit(.deletePage(page: self.pageIndex))
            }
        case "zoom": zoomCommand(n)
        case "objectType":
            canvas.filter = [nil, .text, .image, .path][max(0, min(3, n))]
            canvas.selection = canvas.selection.filter { id in canvas.objects.first { $0.id == id }.map { canvas.filter == nil || $0.kind == canvas.filter } ?? false }
        case "details":
            showDetails.toggle()
            reloadObjects()
        case "objects": showObjectList(source: source)
        default: break
        }
        ribbon?.refresh()
    }

    // MARK: Modes

    private func setMode(_ m: Mode) {
        commitTextEdit()
        if mode == .pen && m != .pen { finishInk() }
        if mode == .read, m != .read, let current = reader.currentPage, reader.document === doc.pdf, let i = doc.pdf?.index(for: current) {
            pageIndex = i
        }
        mode = m
        modes.selectedSegmentIndex = m.rawValue
        reader.isHidden = m != .read
        scroll.isHidden = m == .read
        if m == .read {
            if reader.document !== doc.pdf { reader.document = doc.pdf }
            if let page = doc.pdf?.page(at: pageIndex) { reader.go(to: page) }
        } else {
            showPage()
        }
        if m == .pen { beginInk() }
        ribbon?.refresh()
    }

    // MARK: Pages

    private func documentChanged() {
        let count = doc.pdf?.pageCount ?? 0
        pageIndex = max(0, min(pageIndex, count - 1))
        if thumbnailRevision != doc.revision { thumbnailCache = [:]; thumbnailRevision = doc.revision }
        sidebar.reloadData()
        if mode == .read { reader.document = doc.pdf; if let p = doc.pdf?.page(at: pageIndex) { reader.go(to: p) } }
        showPage(keepSelection: true)
        updateChrome()
    }

    private func go(to index: Int) {
        guard let count = doc.pdf?.pageCount, count > 0 else { return }
        let i = max(0, min(count - 1, index))
        commitTextEdit()
        if mode == .pen { finishInk() }
        pageIndex = i
        if mode == .read, let page = doc.pdf?.page(at: i) { reader.go(to: page) } else { showPage() }
        if mode == .pen { beginInk() }
        sidebar.selectItem(at: IndexPath(item: i, section: 0), animated: true, scrollPosition: .centeredVertically)
    }

    private var fitMode = 0   // 0 page, 1 width, 2 fixed

    private func showPage(keepSelection: Bool = false) {
        let previous = keepSelection ? canvas.selectedObjects : []
        let page = doc.pdf?.page(at: pageIndex)
        scroll.zoomScale = 1
        canvas.show(page, width: canvasWidth())
        canvas.frame.origin = .zero
        scroll.contentSize = canvas.frame.size
        centerCanvas()
        reloadObjects()
        if !previous.isEmpty {
            // Re-select what was edited (objects move between revisions).
            canvas.selection = canvas.objects.filter { o in previous.contains { p in p.kind == o.kind && p.bounds.insetBy(dx: -40, dy: -40).contains(o.bounds.center) } }.prefix(previous.count).map(\.id)
        }
        highlightMatches()
        updateStatus()
    }

    private func canvasWidth() -> CGFloat {
        let available = max(200, scroll.bounds.width - 40)
        let size = canvas.page.map { _ in canvas.displaySize } ?? (doc.pdf?.page(at: pageIndex)?.bounds(for: .mediaBox).size ?? CGSize(width: 612, height: 792))
        let pageSize = doc.pdf?.page(at: pageIndex).map { p -> CGSize in
            let b = p.bounds(for: .mediaBox)
            return p.rotation % 180 == 0 ? b.size : CGSize(width: b.height, height: b.width)
        } ?? size
        switch fitMode {
        case 1: return available
        case 2: return pageSize.width * fixedZoom
        default:
            let heightFit = (scroll.bounds.height - 40) * pageSize.width / max(1, pageSize.height)
            return max(200, min(available, heightFit))
        }
    }
    private var fixedZoom: CGFloat = 1

    private func layoutCanvas(fit: Int) {
        fitMode = fit
        showPage(keepSelection: true)
    }

    private func zoomCommand(_ n: Int) {
        switch n {
        case 0: layoutCanvas(fit: 0)
        case 1: layoutCanvas(fit: 1)
        default: fixedZoom = [0.75, 1, 1.5, 2][max(0, min(3, n - 2))]; layoutCanvas(fit: 2)
        }
    }

    private func centerCanvas() {
        let size = canvas.frame.size
        let dx = max(20, (scroll.bounds.width - size.width) / 2), dy = max(20, (scroll.bounds.height - size.height) / 2)
        scroll.contentInset = UIEdgeInsets(top: dy, left: dx, bottom: dy, right: dx)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { mode == .read ? nil : canvas }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerCanvas() }
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) { canvas.rerender(zoom: scale) }

    private func reloadObjects() {
        guard let page = doc.pdf?.page(at: pageIndex) else { canvas.objects = []; return }
        canvas.objects = PDFObjectFinder.objects(on: page, groupPaths: !showDetails)
        canvas.selection = canvas.selection.filter { id in canvas.objects.contains { $0.id == id } }
    }

    private func updateStatus() {
        let count = doc.pdf?.pageCount ?? 0
        let sel = canvas.selectedObjects
        var text = "\(count == 0 ? 0 : pageIndex + 1) / \(count)"
        if let first = sel.first { text += sel.count == 1 ? "  ·  \(first.typeTitle)" : "  ·  개체 \(sel.count)개" }
        status.text = text
    }

    private func selectionChanged() {
        updateStatus()
        ribbon?.refresh()
    }

    /// Centre of the visible part of the page, in page space.
    private func visibleCenter() -> CGPoint {
        let visible = scroll.convert(scroll.bounds, to: canvas).intersection(canvas.bounds)
        let center = visible.isNull ? CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY) : CGPoint(x: visible.midX, y: visible.midY)
        return canvas.pagePoint(center)
    }

    // MARK: Operations

    private func applyEdit(_ op: PDFEditOperation) {
        do {
            try doc.apply(op)
        } catch {
            presentError(error)
        }
    }

    private func nudge(_ dx: CGFloat, _ dy: CGFloat) {
        guard let r = canvas.selectionBounds else { return }
        // Arrow keys move in display directions; convert through the rotation.
        let a = canvas.pagePoint(.zero), b = canvas.pagePoint(CGPoint(x: dx * canvas.scale, y: -dy * canvas.scale))
        applyEdit(.transform(page: pageIndex, from: r, to: r.offsetBy(dx: b.x - a.x, dy: b.y - a.y), quarterTurns: 0))
    }

    private func addText() {
        promptText("텍스트 추가", text: "", placeholder: "넣을 텍스트") { [weak self] value in
            guard let self, let value, !value.isEmpty else { return }
            let size: CGFloat = 14
            let w = PDFEditEngine.measure(value, size: size, fontName: "", bold: false) + 4
            let lines = CGFloat(value.components(separatedBy: "\n").count)
            let c = self.visibleCenter()
            let rect = CGRect(x: c.x - w / 2, y: c.y - size * lines / 2, width: w, height: size * 1.3 * lines)
            self.applyEdit(.addText(page: self.pageIndex, rect: rect, text: value, fontSize: size, color: .black, fontName: "", bold: false))
        }
    }

    private func copySelectedText() {
        let text = canvas.selectedObjects.filter { $0.kind == .text }.map(\.text).joined(separator: "\n")
        if !text.isEmpty { UIPasteboard.general.string = text }
    }

    private func insertPDF() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.pdf], asCopy: true)
        let delegate = FontImportDelegate { [weak self] urls in
            guard let self, let url = urls.first, let data = try? Data(contentsOf: url) else { return }
            self.applyEdit(.insertPages(at: self.pageIndex + 1, pdf: data))
        }
        pickerDelegate = delegate
        picker.delegate = delegate
        present(picker, animated: true)
    }
    private var pickerDelegate: FontImportDelegate?

    private func convertToDocument() {
        do {
            let model = try PDFReader.read(doc.data)
            openGeneratedDocument(data: DOCXWriter(model).write(), name: doc.displayTitle + " (문서)", ext: "docx")
        } catch { presentError(error) }
    }

    // MARK: Inline text editing

    private func beginTextEdit(_ o: PDFPageObject) {
        commitTextEdit()
        guard mode == .edit else { return }
        let r = canvas.viewRect(o.bounds)
        let tv = UITextView(frame: r.insetBy(dx: -4, dy: -4).integral)
        tv.text = o.text
        tv.font = PDFEditEngine.font(name: o.fontName, size: o.fontSize * canvas.scale, bold: o.bold, italic: o.italic)
        tv.textColor = o.color.uiColor
        tv.backgroundColor = UIColor.white.withAlphaComponent(0.96)
        tv.layer.borderColor = HanXTheme.accent.cgColor
        tv.layer.borderWidth = 1.5
        tv.textContainerInset = UIEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        tv.textContainer.lineFragmentPadding = 0
        tv.isScrollEnabled = false
        tv.delegate = self
        tv.autocorrectionType = .no
        let natural = tv.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        tv.frame.size.width = max(tv.frame.width, natural.width + 8)
        canvas.addSubview(tv)
        inlineEditor = tv
        editingObject = o
        tv.becomeFirstResponder()
        tv.selectAll(nil)
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        if text == "\n" {
            // Return commits the edit; PDF text lines are single lines.
            commitTextEdit()
            return false
        }
        return true
    }

    func textViewDidChange(_ textView: UITextView) {
        let natural = textView.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        textView.frame.size.width = max(textView.frame.width, natural.width + 8)
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        if textView === inlineEditor { commitTextEdit() }
    }

    private func commitTextEdit() {
        guard let tv = inlineEditor, let o = editingObject else { return }
        inlineEditor = nil
        editingObject = nil
        let text = tv.text ?? ""
        tv.removeFromSuperview()
        guard text != o.text else { return }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            applyEdit(.delete(page: pageIndex, rects: [o.bounds]))
        } else {
            applyEdit(.setText(page: pageIndex, object: o, text: text, fontSize: o.fontSize, color: o.color))
        }
    }

    override func commitPendingEdits() {
        commitTextEdit()
        if mode == .pen { finishInk(); beginInk() }
    }

    // MARK: Geometry popover

    private func showGeometry(source: Any?) {
        guard let r = canvas.selectionBounds else { return }
        let box = canvas.pageBox
        // Shown with the origin at the page's top-left, like the macOS inspector.
        let top = box.maxY - r.maxY
        promptNumbers("크기와 위치 (pt)", fields: [("X", Double(r.minX - box.minX)), ("Y", Double(top)), ("너비", Double(r.width)), ("높이", Double(r.height))]) { [weak self] v in
            guard let self, let v, v.count == 4, v[2] >= 1, v[3] >= 1 else { return }
            let target = CGRect(x: box.minX + v[0], y: box.maxY - v[1] - v[3], width: v[2], height: v[3])
            self.applyEdit(.transform(page: self.pageIndex, from: r, to: target, quarterTurns: 0))
        }
    }

    // MARK: Object list

    private func showObjectList(source: Any?) {
        let list = PDFObjectListViewController(objects: canvas.objects, filter: canvas.filter) { [weak self] id in
            guard let self else { return }
            self.canvas.selection = [id]
            if let o = self.canvas.objects.first(where: { $0.id == id }) {
                self.scroll.zoom(to: self.canvas.viewRect(o.bounds).insetBy(dx: -80, dy: -80), animated: true)
            }
        }
        presentPopover(UINavigationController(rootViewController: list), from: source, size: CGSize(width: 360, height: 520))
    }

    // MARK: Find

    private func buildFindBar() {
        findBar.backgroundColor = HanXTheme.toolbar
        findField.placeholder = "PDF에서 찾기"
        findField.borderStyle = .roundedRect
        findField.clearButtonMode = .whileEditing
        findField.returnKeyType = .search
        findField.autocorrectionType = .no
        findField.addAction(UIAction { [weak self] _ in self?.search() }, for: .editingChanged)
        findField.addAction(UIAction { [weak self] _ in self?.stepMatch(1) }, for: .editingDidEndOnExit)
        findCount.font = .systemFont(ofSize: 12)
        findCount.textColor = HanXTheme.secondary
        func b(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> UIButton {
            let btn = UIButton(configuration: .bordered(), primaryAction: UIAction { _ in action() })
            btn.configuration?.image = UIImage(systemName: symbol)
            btn.accessibilityLabel = label
            return btn
        }
        let stack = UIStackView(arrangedSubviews: [findField, findCount, b("chevron.up", "이전 결과") { [weak self] in self?.stepMatch(-1) },
                                                   b("chevron.down", "다음 결과") { [weak self] in self?.stepMatch(1) }, b("xmark", "찾기 닫기") { [weak self] in self?.showFind(nil) }])
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        findBar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: findBar.topAnchor, constant: 8), stack.bottomAnchor.constraint(equalTo: findBar.bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: findBar.leadingAnchor, constant: 12), stack.trailingAnchor.constraint(equalTo: findBar.trailingAnchor, constant: -12),
        ])
    }

    override func showFind(_ sender: Any?) {
        if mode == .read { reader.findInteraction.presentFindNavigator(showingReplace: false); return }
        let show = findBar.isHidden
        UIView.animate(withDuration: 0.2) { self.findBar.isHidden = !show }
        if show { findField.becomeFirstResponder() } else { matches = []; highlightMatches(); view.endEditing(true) }
        ribbon?.refresh()
    }

    private func search() {
        matches = []
        matchIndex = -1
        let q = findField.text ?? ""
        if let pdf = doc.pdf, !q.isEmpty {
            for s in pdf.findString(q, withOptions: [.caseInsensitive]) {
                for p in s.pages { matches.append((pdf.index(for: p), s.bounds(for: p))) }
            }
        }
        findCount.text = q.isEmpty ? "" : "\(matches.count)개"
        if !matches.isEmpty { stepMatch(1) } else { highlightMatches() }
    }

    private func stepMatch(_ delta: Int) {
        guard !matches.isEmpty else { return }
        matchIndex = (matchIndex + delta + matches.count) % matches.count
        let m = matches[matchIndex]
        if m.page != pageIndex { go(to: m.page) }
        highlightMatches()
        findCount.text = "\(matchIndex + 1) / \(matches.count)"
        scroll.scrollRectToVisible(canvas.convert(canvas.viewRect(m.rect).insetBy(dx: -60, dy: -60), to: scroll), animated: true)
    }

    private func highlightMatches() {
        canvas.highlights = matches.filter { $0.page == pageIndex }.map(\.rect)
    }

    // MARK: OCR

    private func runOCR() {
        guard let page = doc.pdf?.page(at: pageIndex) else { return }
        status.text = "문자 인식 중…"
        PDFOCR.recognize(page: page) { [weak self] result in
            guard let self else { return }
            self.updateStatus()
            switch result {
            case .failure(let error): self.presentError(error)
            case .success(let lines):
                let sheet = OCRResultViewController(lines: lines) { [weak self] in
                    guard let self else { return }
                    self.applyEdit(.textLayer(page: self.pageIndex, lines: lines.map { ($0.text, $0.bounds) }))
                }
                self.presentSheet(sheet, size: CGSize(width: 600, height: 640))
            }
        }
    }

    // MARK: Pen (PencilKit)

    private func beginInk() {
        guard inkCanvas == nil else { return }
        let ink = PKCanvasView(frame: canvas.bounds)
        ink.backgroundColor = .clear
        ink.isOpaque = false
        ink.drawingPolicy = .default
        ink.isScrollEnabled = false
        ink.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        canvas.addSubview(ink)
        inkCanvas = ink
        let picker = toolPicker ?? PKToolPicker()
        toolPicker = picker
        picker.setVisible(true, forFirstResponder: ink)
        picker.addObserver(ink)
        ink.becomeFirstResponder()
    }

    /// Bakes the strokes into the page as an image, then clears the overlay.
    private func finishInk() {
        guard let ink = inkCanvas else { return }
        inkCanvas = nil
        toolPicker?.setVisible(false, forFirstResponder: ink)
        toolPicker?.removeObserver(ink)
        let drawing = ink.drawing
        ink.removeFromSuperview()
        guard !drawing.strokes.isEmpty else { return }
        let bounds = drawing.bounds.insetBy(dx: -4, dy: -4).intersection(canvas.bounds)
        guard bounds.width > 1, bounds.height > 1 else { return }
        let image = drawing.image(from: bounds, scale: max(3, 3 / max(0.1, canvas.scale)))
        guard let png = image.pngData() else { return }
        applyEdit(.addImage(page: pageIndex, rect: canvas.pageRect(bounds), data: png))
    }

    // MARK: Sidebar

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { doc.pdf?.pageCount ?? 0 }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "page", for: indexPath) as! PDFThumbnailCell
        let i = indexPath.item
        cell.number.text = "\(i + 1)"
        cell.isCurrent = i == pageIndex
        if let image = thumbnailCache[i] { cell.image.image = image }
        else {
            cell.image.image = nil
            let revision = doc.revision
            if let page = doc.pdf?.page(at: i) {
                DispatchQueue.main.async { [weak self, weak cell] in
                    guard let self, self.doc.revision == revision else { return }
                    let image = page.thumbnail(of: CGSize(width: 200, height: 260), for: .cropBox)
                    self.thumbnailCache[i] = image
                    if let cell, cell.number.text == "\(i + 1)" { cell.image.image = image }
                }
            }
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        go(to: indexPath.item)
        collectionView.reloadData()
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
        guard let i = indexPaths.first?.item else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            UIMenu(children: [
                UIAction(title: "왼쪽으로 회전", image: UIImage(systemName: "rotate.left")) { _ in self?.applyEdit(.rotatePage(page: i, degrees: -90)) },
                UIAction(title: "오른쪽으로 회전", image: UIImage(systemName: "rotate.right")) { _ in self?.applyEdit(.rotatePage(page: i, degrees: 90)) },
                UIAction(title: "복제", image: UIImage(systemName: "plus.square.on.square")) { _ in self?.applyEdit(.duplicatePage(page: i)) },
                UIAction(title: "앞에 빈 페이지", image: UIImage(systemName: "doc.badge.plus")) { _ in
                    let size = self?.doc.pdf?.page(at: i)?.bounds(for: .mediaBox).size ?? CGSize(width: 595, height: 842)
                    self?.applyEdit(.insertBlankPage(at: i, size: size))
                },
                UIAction(title: "뒤에 빈 페이지", image: UIImage(systemName: "doc.badge.plus")) { _ in
                    let size = self?.doc.pdf?.page(at: i)?.bounds(for: .mediaBox).size ?? CGSize(width: 595, height: 842)
                    self?.applyEdit(.insertBlankPage(at: i + 1, size: size))
                },
                UIAction(title: "삭제", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in self?.applyEdit(.deletePage(page: i)) },
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
        guard let item = coordinator.items.first, let from = item.dragItem.localObject as? Int,
              let to = coordinator.destinationIndexPath?.item else { return }
        let count = doc.pdf?.pageCount ?? 0
        let target = max(0, min(count - 1, to))
        guard from != target else { return }
        applyEdit(.movePage(from: from, to: target))
        pageIndex = target
        documentChanged()
    }
}

extension PDFEditorViewController: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard mode == .edit, let o = canvas.object(at: location) else { return nil }
        if !canvas.selection.contains(o.id) { canvas.selection = [o.id] }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            var items: [UIMenuElement] = []
            if o.kind == .text {
                items.append(UIAction(title: "텍스트 수정", image: UIImage(systemName: "pencil")) { _ in self?.beginTextEdit(o) })
                items.append(UIAction(title: "텍스트 복사", image: UIImage(systemName: "doc.on.doc")) { _ in UIPasteboard.general.string = o.text })
            }
            if o.kind == .image { items.append(UIAction(title: "이미지 교체", image: UIImage(systemName: "photo")) { _ in self?.command("replaceImage", "", 0) }) }
            items.append(UIAction(title: "크기와 위치…", image: UIImage(systemName: "ruler")) { _ in self?.command("geometry", "", 0) })
            items.append(UIAction(title: "왼쪽으로 90°", image: UIImage(systemName: "rotate.left")) { _ in self?.command("rotateLeft", "", 0) })
            items.append(UIAction(title: "오른쪽으로 90°", image: UIImage(systemName: "rotate.right")) { _ in self?.command("rotateRight", "", 0) })
            items.append(UIAction(title: "삭제", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in self?.command("delete", "", 0) })
            return UIMenu(children: items)
        })
    }
}

final class PDFThumbnailCell: UICollectionViewCell {
    let image = UIImageView()
    let number = UILabel()
    var isCurrent = false { didSet { updateBorder() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        image.contentMode = .scaleAspectFit
        image.backgroundColor = .white
        image.layer.borderWidth = 1
        number.font = .systemFont(ofSize: 11)
        number.textAlignment = .center
        number.textColor = HanXTheme.secondary
        let stack = UIStackView(arrangedSubviews: [image, number])
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor), stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor), stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            number.heightAnchor.constraint(equalToConstant: 14),
        ])
        updateBorder()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isSelected: Bool { didSet { updateBorder() } }

    private func updateBorder() {
        let on = isCurrent || isSelected
        image.layer.borderColor = (on ? HanXTheme.accent : HanXTheme.border).cgColor
        image.layer.borderWidth = on ? 2.5 : 1
    }
}

final class PDFObjectListViewController: UITableViewController {
    private let objects: [PDFPageObject]
    private let onSelect: (Int) -> Void

    init(objects: [PDFPageObject], filter: PDFPageObject.Kind?, onSelect: @escaping (Int) -> Void) {
        self.objects = objects.filter { filter == nil || $0.kind == filter }
        self.onSelect = onSelect
        super.init(style: .insetGrouped)
        title = "개체 \(self.objects.count)개"
    }
    required init?(coder: NSCoder) { fatalError() }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { objects.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "o") ?? UITableViewCell(style: .subtitle, reuseIdentifier: "o")
        let o = objects[indexPath.row]
        var c = cell.defaultContentConfiguration()
        c.text = o.title
        c.textProperties.numberOfLines = 1
        c.secondaryText = "\(o.typeTitle) · \(Int(o.bounds.width)) × \(Int(o.bounds.height)) pt"
        c.image = UIImage(systemName: o.kind == .text ? "textformat" : o.kind == .image ? "photo" : "square.on.circle")
        cell.contentConfiguration = c
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        onSelect(objects[indexPath.row].id)
        dismiss(animated: true)
    }
}

final class OCRResultViewController: UIViewController {
    private let lines: [PDFOCR.Line]
    private let onAddLayer: () -> Void

    init(lines: [PDFOCR.Line], onAddLayer: @escaping () -> Void) {
        self.lines = lines
        self.onAddLayer = onAddLayer
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "문자 인식"
        view.backgroundColor = .systemBackground
        let text = lines.map(\.text).joined(separator: "\n")
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "복사", image: UIImage(systemName: "doc.on.doc"), primaryAction: UIAction { _ in
            UIPasteboard.general.string = text
        })
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        let tv = UITextView()
        tv.text = text.isEmpty ? "인식한 글자가 없습니다." : text
        tv.font = .systemFont(ofSize: 16)
        tv.isEditable = false
        tv.translatesAutoresizingMaskIntoConstraints = false
        var config = UIButton.Configuration.filled()
        config.title = "검색 가능한 텍스트로 페이지에 추가"
        config.subtitle = "보이지 않는 글자를 넣어 찾기와 복사가 되게 합니다"
        let add = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true) { self?.onAddLayer() }
        })
        add.isEnabled = !lines.isEmpty
        add.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tv)
        view.addSubview(add)
        NSLayoutConstraint.activate([
            tv.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tv.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            tv.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            add.topAnchor.constraint(equalTo: tv.bottomAnchor, constant: 12),
            add.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            add.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            add.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
        ])
    }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
