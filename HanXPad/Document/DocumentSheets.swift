import UIKit

// MARK: - 표 편집

/// Edits a document table: cell text (styles kept), rows, columns, merges,
/// cell colour, vertical alignment and column widths.
final class TableEditorViewController: UIViewController, UITextViewDelegate {
    var onDone: ((Table) -> Void)?
    private var table: Table
    private let source: SourceFormat
    private let scroll = UIScrollView()
    private let grid = UIView()
    private var editors: [(view: UITextView, row: Int, col: Int)] = []
    private var focus = TableModelEditing.Origin(row: 0, col: 0)
    private let undo = UndoManager()

    init(table: Table, source: SourceFormat) {
        self.table = TableModelEditing.normalized(table)
        self.source = source
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var undoManager: UndoManager? { undo }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "표 편집"
        view.backgroundColor = HanXTheme.canvas
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            self.view.endEditing(true)
            self.onDone?(self.table)
            self.dismiss(animated: true)
        })
        let rowMenu = UIMenu(title: "줄", children: [
            UIAction(title: "위에 줄 추가", image: UIImage(systemName: "arrow.up.to.line")) { [weak self] _ in self?.structural { TableModelEditing.insertRow($0, at: $1.row) } },
            UIAction(title: "아래에 줄 추가", image: UIImage(systemName: "arrow.down.to.line")) { [weak self] _ in self?.structural { TableModelEditing.insertRow($0, at: $1.row + 1) } },
            UIAction(title: "줄 삭제", image: UIImage(systemName: "minus.rectangle"), attributes: .destructive) { [weak self] _ in self?.structural { TableModelEditing.deleteRow($0, at: $1.row) } },
        ])
        let colMenu = UIMenu(title: "칸", children: [
            UIAction(title: "왼쪽에 칸 추가", image: UIImage(systemName: "arrow.left.to.line")) { [weak self] _ in self?.structural { TableModelEditing.insertColumn($0, at: $1.col) } },
            UIAction(title: "오른쪽에 칸 추가", image: UIImage(systemName: "arrow.right.to.line")) { [weak self] _ in self?.structural { TableModelEditing.insertColumn($0, at: $1.col + 1) } },
            UIAction(title: "칸 삭제", image: UIImage(systemName: "minus.rectangle.portrait"), attributes: .destructive) { [weak self] _ in self?.structural { TableModelEditing.deleteColumn($0, at: $1.col) } },
            UIAction(title: "칸 넓게", image: UIImage(systemName: "arrow.left.and.right")) { [weak self] _ in self?.resizeColumn(1.15) },
            UIAction(title: "칸 좁게", image: UIImage(systemName: "arrow.right.and.line.vertical.and.arrow.left")) { [weak self] _ in self?.resizeColumn(1 / 1.15) },
            UIAction(title: "칸 너비 같게", image: UIImage(systemName: "equal.square")) { [weak self] _ in self?.equalizeColumns() },
        ])
        let mergeMenu = UIMenu(title: "셀 합치기", children: [
            UIAction(title: "오른쪽 셀과 합치기") { [weak self] _ in self?.mergeFocused(down: false) },
            UIAction(title: "아래 셀과 합치기") { [weak self] _ in self?.mergeFocused(down: true) },
            UIAction(title: "셀 나누기") { [weak self] _ in self?.structural { TableModelEditing.split($0, row: $1.row, col: $1.col) } },
        ])
        let fillMenu = UIMenu(title: "셀 배경", children: [UIAction(title: "배경 없음") { [weak self] _ in self?.setFill(nil) }]
            + Palette.names.enumerated().map { i, name in UIAction(title: name) { [weak self] _ in self?.setFill(Palette.colors[i]) } })
        let alignMenu = UIMenu(title: "세로 정렬", children: [
            UIAction(title: "위") { [weak self] _ in self?.setVAlign(.top) },
            UIAction(title: "가운데") { [weak self] _ in self?.setVAlign(.center) },
            UIAction(title: "아래") { [weak self] _ in self?.setVAlign(.bottom) },
        ])
        let toolbar = UIToolbar()
        toolbar.items = [
            UIBarButtonItem(title: "줄", image: UIImage(systemName: "rectangle.split.1x2"), menu: rowMenu),
            UIBarButtonItem(title: "칸", image: UIImage(systemName: "rectangle.split.2x1"), menu: colMenu),
            UIBarButtonItem(title: "합치기", image: UIImage(systemName: "rectangle.compress.vertical"), menu: mergeMenu),
            UIBarButtonItem(title: "배경", image: UIImage(systemName: "paintbrush"), menu: fillMenu),
            UIBarButtonItem(title: "정렬", image: UIImage(systemName: "align.vertical.center"), menu: alignMenu),
            .flexibleSpace(),
            UIBarButtonItem(image: UIImage(systemName: "arrow.uturn.backward"), primaryAction: UIAction { [weak self] _ in self?.undo.undo() }),
            UIBarButtonItem(image: UIImage(systemName: "arrow.uturn.forward"), primaryAction: UIAction { [weak self] _ in self?.undo.redo() }),
        ]
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(grid)
        view.addSubview(toolbar)
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if grid.bounds.width == 0 || abs(lastWidth - scroll.bounds.width) > 1 { lastWidth = scroll.bounds.width; rebuild() }
    }
    private var lastWidth: CGFloat = 0

    private func rebuild() {
        let previous = focus
        grid.subviews.forEach { $0.removeFromSuperview() }
        editors = []
        let t = table
        let available = max(320, scroll.bounds.width - 32)
        let total = max(1, t.columnWidths.reduce(0, +))
        let widths = t.columnWidths.map { max(64, CGFloat($0) / CGFloat(total) * available) }
        let rowHeight: CGFloat = 64
        func x(_ c: Int) -> CGFloat { 16 + widths.prefix(c).reduce(0, +) }
        let owner = TableModelEditing.owners(t)
        for r in t.rows.indices {
            for c in 0..<t.columnCount {
                guard let o = owner[r][c], o.row == r, o.col == c else { continue }
                let cell = t.rows[r][c]
                let rs = max(1, min(cell.rowSpan, t.rows.count - r)), cs = max(1, min(cell.colSpan, t.columnCount - c))
                let frame = CGRect(x: x(c), y: 16 + CGFloat(r) * rowHeight, width: x(c + cs) - x(c), height: CGFloat(rs) * rowHeight)
                let tv = UITextView(frame: frame.insetBy(dx: 0.5, dy: 0.5))
                tv.font = .systemFont(ofSize: 15)
                tv.text = SlideTableEditing.text(cell)
                tv.backgroundColor = cell.background?.uiColor ?? .white
                tv.textColor = .black
                tv.layer.borderColor = UIColor(white: 0.7, alpha: 1).cgColor
                tv.layer.borderWidth = 0.5
                tv.delegate = self
                tv.tag = r * 10_000 + c
                let nested = cell.blocks.contains { if case .table = $0 { return true }; return false }
                tv.isEditable = !nested
                if nested { tv.text = (tv.text ?? "") + "\n(안쪽 표는 본문에서 편집)" ; tv.textColor = .secondaryLabel }
                grid.addSubview(tv)
                editors.append((tv, r, c))
            }
        }
        let width = x(t.columnCount) + 16
        grid.frame = CGRect(x: 0, y: 0, width: width, height: 32 + CGFloat(t.rows.count) * rowHeight)
        scroll.contentSize = grid.frame.size
        focus = previous
        highlightFocus()
    }

    private func highlightFocus() {
        for e in editors {
            let on = e.row == focus.row && e.col == focus.col
            e.view.layer.borderColor = on ? HanXTheme.accent.cgColor : UIColor(white: 0.7, alpha: 1).cgColor
            e.view.layer.borderWidth = on ? 2 : 0.5
        }
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        focus = TableModelEditing.Origin(row: textView.tag / 10_000, col: textView.tag % 10_000)
        highlightFocus()
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        let r = textView.tag / 10_000, c = textView.tag % 10_000
        let updated = SlideTableEditing.settingText(table, row: r, column: c, text: textView.text ?? "")
        setTable(updated, rebuildViews: false)
    }

    private func setTable(_ t: Table, rebuildViews: Bool = true) {
        let old = table
        table = t
        undo.registerUndo(withTarget: self) { $0.setTable(old) }
        if rebuildViews { rebuild() }
    }

    private func structural(_ change: (Table, TableModelEditing.Origin) -> Table) {
        view.endEditing(true)
        setTable(change(table, focus))
        focus.row = min(focus.row, table.rows.count - 1)
        focus.col = min(focus.col, table.columnCount - 1)
        highlightFocus()
    }

    private func mergeFocused(down: Bool) {
        view.endEditing(true)
        guard let merged = TableModelEditing.merge(table, row: focus.row, col: focus.col, down: down) else {
            presentMessage("합칠 수 없습니다", "합칠 두 셀의 높이(또는 너비)가 같아야 합니다.")
            return
        }
        setTable(merged)
    }

    private func setFill(_ color: RGB?) {
        view.endEditing(true)
        var t = table
        t.rows[focus.row][focus.col].background = color
        setTable(t)
    }

    private func setVAlign(_ v: CellVAlign) {
        view.endEditing(true)
        var t = table
        t.rows[focus.row][focus.col].verticalAlign = v
        setTable(t)
    }

    private func resizeColumn(_ factor: Double) {
        view.endEditing(true)
        var t = table
        guard t.columnWidths.indices.contains(focus.col) else { return }
        let total = t.columnWidths.reduce(0, +)
        t.columnWidths[focus.col] = max(8, t.columnWidths[focus.col] * factor)
        // Keep the table width: the other columns give or take the difference.
        let others = t.columnWidths.indices.filter { $0 != focus.col }
        let rest = others.map { t.columnWidths[$0] }.reduce(0, +)
        if rest > 0 {
            let scale = max(0.05, (total - t.columnWidths[focus.col]) / rest)
            for i in others { t.columnWidths[i] = max(8, t.columnWidths[i] * scale) }
        }
        for r in t.rows.indices { t.rows[r][focus.col].width = nil }
        setTable(t)
    }

    private func equalizeColumns() {
        view.endEditing(true)
        var t = table
        let total = t.columnWidths.reduce(0, +)
        t.columnWidths = Array(repeating: total / Double(max(1, t.columnWidths.count)), count: t.columnWidths.count)
        setTable(t)
    }
}

// MARK: - 머리말 꼬리말

final class HeaderFooterViewController: UIViewController {
    var onDone: (([Block]?, [Block]?) -> Void)?
    private let headerView = UITextView()
    private let footerView = UITextView()
    private let images: [String: ImageData]
    private let source: SourceFormat
    private weak var lastFocused: UITextView?

    init(header: [Block]?, footer: [Block]?, images: [String: ImageData], source: SourceFormat, width: Double) {
        self.images = images
        self.source = source
        super.init(nibName: nil, bundle: nil)
        let ctx = TextBridge.Context(images: images, source: source)
        for (view, blocks) in [(headerView, header), (footerView, footer)] {
            let s = TextBridge.build(blocks ?? [], width: width, ctx: ctx)
            if s.length > 0, (s.string as NSString).character(at: s.length - 1) == 10 { s.deleteCharacters(in: NSRange(location: s.length - 1, length: 1)) }
            view.attributedText = s
            view.typingAttributes = TextBridge.charAttributes({ var c = TextDocument.defaultCharProps(for: source); c.size = 9; return c }(), eastAsian: true)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "머리말 꼬리말"
        view.backgroundColor = HanXTheme.canvas
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.finish() })
        func label(_ text: String) -> UILabel {
            let l = UILabel(); l.text = text; l.font = .systemFont(ofSize: 13, weight: .semibold); l.textColor = HanXTheme.secondary; return l
        }
        for v in [headerView, footerView] {
            v.backgroundColor = .white
            v.layer.cornerRadius = 8
            v.layer.borderColor = HanXTheme.border.cgColor
            v.layer.borderWidth = 1
            v.allowsEditingTextAttributes = true
            v.heightAnchor.constraint(equalToConstant: 120).isActive = true
            v.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        }
        func fieldButton(_ title: String, _ kind: FieldKind) -> UIButton {
            var c = UIButton.Configuration.bordered()
            c.title = title
            c.image = UIImage(systemName: "number")
            c.imagePadding = 6
            return UIButton(configuration: c, primaryAction: UIAction { [weak self] _ in self?.insertField(kind) })
        }
        let align = UISegmentedControl(items: ["왼쪽", "가운데", "오른쪽"])
        align.addAction(UIAction { [weak self, weak align] _ in self?.align([.left, .center, .right][align?.selectedSegmentIndex ?? 0]) }, for: .valueChanged)
        let tools = UIStackView(arrangedSubviews: [fieldButton("쪽 번호", .page), fieldButton("전체 쪽 수", .pageCount), align, UIView()])
        tools.spacing = 10
        let note = UILabel()
        note.text = "커서가 있는 칸에 쪽 번호를 넣습니다. 모든 쪽에 같은 머리말과 꼬리말을 씁니다."
        note.font = .systemFont(ofSize: 12)
        note.textColor = HanXTheme.secondary
        note.numberOfLines = 0
        let stack = UIStackView(arrangedSubviews: [label("머리말"), headerView, label("꼬리말"), footerView, tools, note])
        stack.axis = .vertical
        stack.spacing = 8
        stack.setCustomSpacing(18, after: headerView)
        stack.setCustomSpacing(18, after: footerView)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
        NotificationCenter.default.addObserver(forName: UITextView.textDidBeginEditingNotification, object: nil, queue: .main) { [weak self] n in
            if let tv = n.object as? UITextView, tv === self?.headerView || tv === self?.footerView { self?.lastFocused = tv }
        }
    }

    private var target: UITextView { lastFocused ?? footerView }

    private func insertField(_ kind: FieldKind) {
        let tv = target
        let props = TextBridge.charProps(tv.typingAttributes)
        let s = NSMutableAttributedString(attributedString: tv.attributedText)
        let r = tv.selectedRange
        s.replaceCharacters(in: r, with: TextBridge.field(kind, props))
        tv.attributedText = s
        tv.selectedRange = NSRange(location: r.location + (kind == .page ? 1 : 4), length: 0)
    }

    private func align(_ a: Alignment) {
        let tv = target
        let ctx = TextBridge.Context(images: images, source: source)
        let s = TextBridge.reparagraphed(tv.attributedText, ctx: ctx) { $0.alignment = a }
        let sel = tv.selectedRange
        tv.attributedText = s
        tv.selectedRange = sel
        var typing = tv.typingAttributes
        for (k, v) in TextBridge.paragraphAttributes({ var p = ParaProps(); p.alignment = a; return p }(), mark: TextBridge.charProps(typing), ctx: ctx) { typing[k] = v }
        tv.typingAttributes = typing
    }

    private func finish() {
        let temp = UDocument()
        temp.images = images
        temp.source = source
        func blocks(_ tv: UITextView) -> [Block]? {
            let text = tv.attributedText ?? NSAttributedString()
            guard !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.string.contains("\u{FFFC}") || hasField(text) else { return nil }
            return TextBridge.blocks(from: text, doc: temp)
        }
        onDone?(blocks(headerView), blocks(footerView))
        dismiss(animated: true)
    }

    private func hasField(_ s: NSAttributedString) -> Bool {
        var found = false
        s.enumerateAttribute(.hwField, in: NSRange(location: 0, length: s.length)) { v, _, stop in if v != nil { found = true; stop.pointee = true } }
        return found
    }
}

// MARK: - 편집 용지

final class PageSetupViewController: UIViewController {
    var onDone: ((PageSetup) -> Void)?
    private var page: PageSetup
    private var fields: [String: UITextField] = [:]
    private let orientation = UISegmentedControl(items: ["세로", "가로"])
    private let paperButton = UIButton(type: .system)

    private static let papers: [(String, Double, Double)] = [
        ("A4 (210 × 297 mm)", 210, 297), ("A5 (148 × 210 mm)", 148, 210), ("B5 (182 × 257 mm)", 182, 257), ("B4 (257 × 364 mm)", 257, 364),
        ("A3 (297 × 420 mm)", 297, 420), ("Letter (216 × 279 mm)", 215.9, 279.4), ("Legal (216 × 356 mm)", 215.9, 355.6),
    ]
    private static func mm(_ pt: Double) -> Double { (pt / 72 * 25.4 * 10).rounded() / 10 }
    private static func pt(_ mm: Double) -> Double { mm / 25.4 * 72 }

    init(page: PageSetup) {
        self.page = page
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "편집 용지"
        view.backgroundColor = HanXTheme.canvas
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.finish() })
        var paper = UIButton.Configuration.bordered()
        paper.title = "용지 종류"
        paper.image = UIImage(systemName: "doc")
        paper.imagePadding = 8
        paperButton.configuration = paper
        paperButton.showsMenuAsPrimaryAction = true
        paperButton.menu = UIMenu(children: PageSetupViewController.papers.map { item in
            UIAction(title: item.0) { [weak self] _ in
                guard let self else { return }
                let landscape = self.orientation.selectedSegmentIndex == 1
                self.fields["width"]?.text = SheetValue.general(landscape ? item.2 : item.1)
                self.fields["height"]?.text = SheetValue.general(landscape ? item.1 : item.2)
            }
        })
        orientation.selectedSegmentIndex = page.width > page.height ? 1 : 0
        orientation.addAction(UIAction { [weak self] _ in
            guard let self, let w = self.fields["width"]?.text, let h = self.fields["height"]?.text,
                  let wv = Double(w), let hv = Double(h) else { return }
            let landscape = self.orientation.selectedSegmentIndex == 1
            self.fields["width"]?.text = SheetValue.general(landscape ? max(wv, hv) : min(wv, hv))
            self.fields["height"]?.text = SheetValue.general(landscape ? min(wv, hv) : max(wv, hv))
        }, for: .valueChanged)

        func row(_ key: String, _ title: String, _ value: Double) -> UIView {
            let l = UILabel(); l.text = title; l.font = .systemFont(ofSize: 15)
            let f = UITextField()
            f.text = SheetValue.general(PageSetupViewController.mm(value))
            f.keyboardType = .decimalPad
            f.borderStyle = .roundedRect
            f.textAlignment = .right
            f.widthAnchor.constraint(equalToConstant: 110).isActive = true
            let unit = UILabel(); unit.text = "mm"; unit.textColor = HanXTheme.secondary
            fields[key] = f
            let s = UIStackView(arrangedSubviews: [l, UIView(), f, unit])
            s.spacing = 8
            s.alignment = .center
            return s
        }
        let stack = UIStackView(arrangedSubviews: [
            paperButton, orientation,
            row("width", "용지 너비", page.width), row("height", "용지 길이", page.height),
            row("top", "위쪽 여백", page.marginTop), row("bottom", "아래쪽 여백", page.marginBottom),
            row("left", "왼쪽 여백", page.marginLeft), row("right", "오른쪽 여백", page.marginRight),
            row("header", "머리말", page.header), row("footer", "꼬리말", page.footer),
        ])
        stack.axis = .vertical
        stack.spacing = 12
        stack.setCustomSpacing(20, after: orientation)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -20),
        ])
    }

    private func finish() {
        func v(_ key: String) -> Double? {
            guard let t = fields[key]?.text?.replacingOccurrences(of: ",", with: "."), let d = Double(t), d.isFinite, d >= 0 else { return nil }
            return PageSetupViewController.pt(d)
        }
        guard let w = v("width"), let h = v("height"), let top = v("top"), let bottom = v("bottom"), let left = v("left"), let right = v("right"),
              let header = v("header"), let footer = v("footer"), w >= 72, h >= 72, w <= 5000, h <= 5000,
              left + right < w - 36, top + bottom < h - 36 else {
            presentMessage("값을 확인하세요", "용지는 25.4mm 이상이어야 하고, 여백을 뺀 본문 영역이 남아야 합니다.")
            return
        }
        page.width = w; page.height = h
        page.marginTop = top; page.marginBottom = bottom; page.marginLeft = left; page.marginRight = right
        page.header = header; page.footer = footer
        onDone?(page)
        dismiss(animated: true)
    }
}
