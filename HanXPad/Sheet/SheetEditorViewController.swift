import UIKit

/// XLSX / CSV editor: formula bar, grid, sheet tabs and the macOS ribbon
/// (홈 · 셀 서식 · 삽입 크기 · 데이터 · 보기).
final class SheetEditorViewController: HanXEditorViewController, SheetGridDelegate, UITextFieldDelegate, UIFontPickerViewControllerDelegate {
    let doc: SheetFileDocument
    private var grid: SheetGridView!
    private let nameBox = UITextField()
    private let formula = UITextField()
    private let tabsScroll = UIScrollView()
    private let tabsStack = UIStackView()
    private var observers: [NSObjectProtocol] = []
    private var lastSearch = ""
    /// Cells copied inside HanX keep their styles; other apps get TSV text.
    private var clipboard: (text: String, cells: [[SheetCell?]], cut: CellRange?, origin: CellRef, sheet: Worksheet)?

    init(document: SheetFileDocument) {
        doc = document
        super.init(baseDocument: document)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    private var sheet: Worksheet { doc.sheet }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildRibbon()
        grid = SheetGridView(sheet: doc.sheet, engine: doc.engine)
        grid.delegate = self

        nameBox.borderStyle = .roundedRect
        nameBox.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        nameBox.textAlignment = .center
        nameBox.autocapitalizationType = .allCharacters
        nameBox.autocorrectionType = .no
        nameBox.returnKeyType = .go
        nameBox.delegate = self
        nameBox.accessibilityLabel = "셀 주소"
        formula.borderStyle = .roundedRect
        formula.font = .systemFont(ofSize: 15)
        formula.placeholder = "값 또는 =수식"
        formula.autocorrectionType = .no
        formula.autocapitalizationType = .none
        formula.smartQuotesType = .no
        formula.returnKeyType = .done
        formula.clearButtonMode = .whileEditing
        formula.delegate = self
        formula.accessibilityLabel = "수식 입력줄"
        let fx = UILabel()
        fx.text = "fx"
        fx.font = .italicSystemFont(ofSize: 16)
        fx.textColor = HanXTheme.secondary
        let bar = UIStackView(arrangedSubviews: [nameBox, fx, formula])
        bar.spacing = 8
        bar.alignment = .center
        bar.isLayoutMarginsRelativeArrangement = true
        bar.layoutMargins = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        bar.backgroundColor = HanXTheme.toolbar
        nameBox.widthAnchor.constraint(equalToConstant: 96).isActive = true

        tabsStack.spacing = 4
        tabsStack.isLayoutMarginsRelativeArrangement = true
        tabsStack.layoutMargins = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        tabsStack.translatesAutoresizingMaskIntoConstraints = false
        tabsScroll.addSubview(tabsStack)
        tabsScroll.showsHorizontalScrollIndicator = false
        tabsScroll.backgroundColor = HanXTheme.toolbar
        NSLayoutConstraint.activate([
            tabsStack.topAnchor.constraint(equalTo: tabsScroll.contentLayoutGuide.topAnchor),
            tabsStack.bottomAnchor.constraint(equalTo: tabsScroll.contentLayoutGuide.bottomAnchor),
            tabsStack.leadingAnchor.constraint(equalTo: tabsScroll.contentLayoutGuide.leadingAnchor),
            tabsStack.trailingAnchor.constraint(equalTo: tabsScroll.contentLayoutGuide.trailingAnchor),
            tabsStack.heightAnchor.constraint(equalTo: tabsScroll.frameLayoutGuide.heightAnchor),
        ])

        let stack = UIStackView(arrangedSubviews: [bar, grid, tabsScroll])
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            tabsScroll.heightAnchor.constraint(equalToConstant: 44),
        ])
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .sheetChanged, object: doc, queue: .main) { [weak self] _ in self?.refresh() })
        observers.append(center.addObserver(forName: .sheetCommitEditing, object: doc, queue: .main) { [weak self] _ in self?.commitPendingEdits() })
        reloadTabs()
        gridSelectionChanged()
    }

    override func didFinishPresenting() {
        super.didFinishPresenting()
        grid.focus()
    }

    private func refresh() {
        if grid.sheet !== doc.sheet { grid.sheet = doc.sheet }
        grid.refresh()
        reloadTabs()
        gridSelectionChanged()
        updateChrome()
    }

    override func commitPendingEdits() {
        grid?.commitEdit()
        if formula.isFirstResponder { formula.resignFirstResponder() }
    }

    // MARK: Sheet tabs

    private func reloadTabs() {
        tabsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, ws) in doc.book.sheets.enumerated() {
            var c = i == doc.currentSheetIndex ? UIButton.Configuration.filled() : UIButton.Configuration.gray()
            c.title = ws.name
            c.cornerStyle = .medium
            c.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14)
            let b = UIButton(configuration: c, primaryAction: UIAction { [weak self] _ in self?.selectSheet(i) })
            b.menu = UIMenu(children: [
                UIAction(title: "이름 바꾸기", image: UIImage(systemName: "pencil")) { [weak self] _ in self?.selectSheet(i); self?.renameSheet() },
                UIAction(title: "시트 삭제", image: UIImage(systemName: "trash"), attributes: doc.book.sheets.count > 1 ? .destructive : .disabled) { [weak self] _ in
                    self?.deleteSheet(i)
                },
            ])
            tabsStack.addArrangedSubview(b)
        }
        let add = UIButton(configuration: .plain(), primaryAction: UIAction { [weak self] _ in self?.addSheet() })
        add.configuration?.image = UIImage(systemName: "plus")
        add.accessibilityLabel = "시트 추가"
        tabsStack.addArrangedSubview(add)
    }

    private func selectSheet(_ i: Int) {
        grid.commitEdit()
        guard doc.book.sheets.indices.contains(i) else { return }
        doc.currentSheetIndex = i
        grid.sheet = doc.sheet
        grid.anchor = CellRef(row: 0, col: 0)
        grid.select(CellRef(row: 0, col: 0))
        reloadTabs()
    }

    private func addSheet() {
        var n = doc.book.sheets.count + 1
        while doc.book.sheet(named: "Sheet\(n)") != nil { n += 1 }
        let i = doc.addSheet(named: "Sheet\(n)")
        selectSheet(i)
    }

    private func renameSheet() {
        let ws = sheet
        promptText("시트 이름", text: ws.name) { [weak self] value in
            guard let self, let value else { return }
            let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 31, !name.contains(where: { "[]:*?/\\".contains($0) }) else {
                self.presentMessage("이름을 쓸 수 없습니다", "1~31자로 입력하고 [ ] : * ? / \\ 는 쓰지 마세요."); return
            }
            if let other = self.doc.book.sheet(named: name), other !== ws { self.presentMessage("같은 이름의 시트가 있습니다", name); return }
            self.doc.renameSheet(ws, to: name)
        }
    }

    private func deleteSheet(_ i: Int) {
        guard doc.book.sheets.count > 1 else { return }
        confirm("시트를 삭제할까요?", message: "‘\(doc.book.sheets[i].name)’ 시트를 삭제합니다. 실행 취소로 되돌릴 수 있습니다.", action: "삭제", destructive: true) { [weak self] in
            guard let self else { return }
            self.doc.removeSheet(at: i)
            self.selectSheet(min(i, self.doc.book.sheets.count - 1))
        }
    }

    // MARK: Grid delegate

    func gridSelectionChanged() {
        let sel = grid.selection
        nameBox.text = sel.start == sel.end ? grid.cursor.a1 : sel.a1
        if !formula.isFirstResponder {
            let ref = sheet.merge(containing: grid.cursor)?.start ?? grid.cursor
            if grid.isEditing {
                formula.text = grid.editor.text
                formula.textColor = .label
            } else if let input = sheet.cells[ref]?.input, !input.isEmpty {
                formula.text = input
                formula.textColor = .label
            } else if let spill = doc.engine.spillRange(sheet, ref), spill.start != ref, let anchorInput = sheet.cells[spill.start]?.input {
                formula.text = anchorInput
                formula.textColor = .secondaryLabel
            } else {
                formula.text = ""
                formula.textColor = .label
            }
        }
        ribbon?.refresh()
    }

    func gridCommit(_ ref: CellRef, input: String) {
        var c = sheet.cells[ref] ?? SheetCell()
        guard c.input != input else { return }
        c.input = input
        doc.setCells([(sheet, ref, c)], actionName: "입력")
    }

    func gridClear(_ range: CellRange) {
        let changes: [(Worksheet, CellRef, SheetCell?)] = sheet.cells.keys.filter { range.contains($0) }.map {
            var c = sheet.cells[$0]!; c.input = ""; return (sheet, $0, c)
        }
        if !changes.isEmpty { doc.setCells(changes, actionName: "지우기") }
    }

    func gridCopy(cut: Bool) {
        let r = grid.expandedSelection
        guard (r.end.row - r.start.row + 1) * (r.end.col - r.start.col + 1) <= 200_000 else { presentMessage("복사할 수 없습니다", "200,000셀 이하를 선택하세요."); return }
        var rows: [String] = []
        var cells: [[SheetCell?]] = []
        for row in r.start.row...r.end.row {
            var line: [String] = []
            var cellRow: [SheetCell?] = []
            for col in r.start.col...r.end.col {
                let ref = CellRef(row: row, col: col)
                line.append(doc.engine.display(sheet, ref))
                cellRow.append(sheet.cells[ref])
            }
            rows.append(line.joined(separator: "\t"))
            cells.append(cellRow)
        }
        let text = rows.joined(separator: "\n")
        UIPasteboard.general.string = text
        clipboard = (text, cells, cut ? r : nil, r.start, sheet)
    }

    func gridPaste() {
        let at = grid.selection.start
        var changes: [(Worksheet, CellRef, SheetCell?)] = []
        if let clip = clipboard, UIPasteboard.general.string == clip.text {
            for (dr, row) in clip.cells.enumerated() {
                for (dc, cell) in row.enumerated() {
                    let target = CellRef(row: at.row + dr, col: at.col + dc)
                    var c = cell
                    // Copies shift relative references; cuts keep them.
                    if var moved = c, moved.isFormula, clip.cut == nil {
                        let source = CellRef(row: clip.origin.row + dr, col: clip.origin.col + dc)
                        moved.input = "=" + XLSXReader.translate(String(moved.input.dropFirst()), rows: target.row - source.row, cols: target.col - source.col)
                        c = moved
                    }
                    changes.append((sheet, target, c))
                }
            }
            if let cut = clip.cut, clip.sheet === sheet {
                for ref in cut.cells where !CellRange(at, CellRef(row: at.row + cut.end.row - cut.start.row, col: at.col + cut.end.col - cut.start.col)).contains(ref) {
                    changes.append((sheet, ref, nil))
                }
                clipboard = nil
            }
        } else if let text = UIPasteboard.general.string {
            let ws = DelimitedText.parse(text, separator: text.contains("\t") ? "\t" : ",")
            for (ref, cell) in ws.cells {
                let target = CellRef(row: at.row + ref.row, col: at.col + ref.col)
                var c = sheet.cells[target] ?? SheetCell()
                c.input = cell.input
                changes.append((sheet, target, c))
            }
        }
        if !changes.isEmpty { doc.setCells(changes, actionName: "붙이기") }
    }

    func gridChartsChanged(from old: [SheetChart], name: String) {
        let new = sheet.charts
        sheet.charts = old
        doc.setCharts(new, on: sheet, name: name)
    }

    func gridResized(columns: [Int: Double], rows: [Int: Double]) {
        doc.setDimensions(columns: columns, rows: rows, on: sheet)
    }

    func gridEditChart(_ index: Int) {
        guard sheet.charts.indices.contains(index) else { return }
        let editor = ChartEditorViewController(chart: sheet.charts[index]) { [weak self] result in
            guard let self, self.sheet.charts.indices.contains(index) else { return }
            var charts = self.sheet.charts
            if let result { charts[index] = result } else { charts.remove(at: index); self.grid.selectedChart = nil }
            self.doc.setCharts(charts, on: self.sheet, name: result == nil ? "차트 삭제" : "차트 설정")
        }
        presentSheet(editor, size: CGSize(width: 480, height: 420))
    }

    func gridMenu(for range: CellRange) -> UIMenu {
        UIMenu(children: [
            UIMenu(options: .displayInline, children: [
                UIAction(title: "잘라내기", image: UIImage(systemName: "scissors")) { [weak self] _ in self?.cutCells() },
                UIAction(title: "복사", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in self?.copyCells() },
                UIAction(title: "붙여넣기", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in self?.gridPaste() },
                UIAction(title: "지우기", image: UIImage(systemName: "delete.left")) { [weak self] _ in self?.gridClear(range) },
                UIAction(title: "편집", image: UIImage(systemName: "pencil")) { [weak self] _ in self?.grid.focus(); self?.grid.beginEdit() },
            ]),
            UIMenu(title: "행과 열", children: [
                UIAction(title: "행 삽입") { [weak self] _ in self?.command("insertRow", "", 0) },
                UIAction(title: "행 삭제") { [weak self] _ in self?.command("deleteRow", "", 0) },
                UIAction(title: "열 삽입") { [weak self] _ in self?.command("insertColumn", "", 0) },
                UIAction(title: "열 삭제") { [weak self] _ in self?.command("deleteColumn", "", 0) },
                UIAction(title: "열 너비 자동 맞춤") { [weak self] _ in self?.command("autofit", "", 0) },
            ]),
            UIAction(title: "셀 병합 / 해제", image: UIImage(systemName: "rectangle.split.2x1")) { [weak self] _ in self?.command("merge", "", 0) },
        ])
    }

    private func copyCells() { gridCopy(cut: false) }
    private func cutCells() { gridCopy(cut: true) }

    // MARK: Formula bar and name box

    func textFieldDidBeginEditing(_ textField: UITextField) {
        if textField === formula {
            grid.commitEdit()
            if formula.textColor == .secondaryLabel { formula.text = ""; formula.textColor = .label }
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === formula {
            let ref = sheet.merge(containing: grid.cursor)?.start ?? grid.cursor
            gridCommit(ref, input: formula.text ?? "")
            formula.resignFirstResponder()
            grid.focus()
            grid.move(rows: 1, cols: 0, extend: false)
        } else if textField === nameBox {
            let parts = (nameBox.text ?? "").uppercased().split(separator: ":").map(String.init)
            if let a = parts.first.flatMap(CellRef.init(a1:)) {
                let b = parts.count > 1 ? CellRef(a1: parts[1]) ?? a : a
                grid.select(b)
                grid.anchor = a
                grid.selectRange(CellRange(a, b))
            } else {
                presentMessage("주소를 확인하세요", "A1 또는 A1:C10처럼 입력하세요.")
            }
            nameBox.resignFirstResponder()
            grid.focus()
        }
        return false
    }

    // MARK: Ribbon

    private func buildRibbon() {
        typealias R = RibbonView
        let fonts = FontResolver.shared.allFamilies
        let clipboard = R.Group(title: "클립보드", items: [.button("cut", "잘라내기", "scissors"), .button("copy", "복사", "doc.on.doc"), .button("paste", "붙여넣기", "doc.on.clipboard")])
        let text = R.Group(title: "글꼴", items: [.field("font", "글꼴", Array(fonts.prefix(30))), .field("size", "글자 크기", ["8", "9", "10", "11", "12", "14", "16", "18", "20", "24", "28", "36"]),
                                                .toggle("bold", "굵게", "bold"), .toggle("italic", "기울임", "italic"), .toggle("underline", "밑줄", "underline")])
        installRibbon([
            .init(title: "홈", groups: [clipboard, text, .init(title: "셀 정렬", items: [
                .toggle("left", "왼쪽", "text.alignleft"), .toggle("center", "가운데", "text.aligncenter"), .toggle("right", "오른쪽", "text.alignright"),
                .toggle("wrap", "줄 바꿈", "text.word.spacing"), .button("merge", "병합 / 해제", "rectangle.split.2x1"),
            ])]),
            .init(title: "셀 서식", groups: [.init(title: "색과 테두리", items: [
                .menu("textColor", "글자 색", R.colorMenu, symbol: "paintpalette"), .menu("fill", "채우기", ["채우기 없음"] + R.colorMenu, symbol: "paintbrush"),
                .toggle("border", "모든 테두리", "square.dashed"), .button("clearFormat", "서식 지우기", "eraser"),
            ]), .init(title: "표시 형식", items: [
                .menu("numberFormat", "표시 형식", ["일반", "숫자 (1,234)", "숫자 (1,234.00)", "통화 (₩)", "백분율 (0%)", "백분율 (0.00%)", "날짜 (2026-01-31)", "날짜 (2026년 1월 31일)"], symbol: "number"),
                .menu("decimal", "소수 자릿수", ["소수 자릿수…", "정수", "1자리", "2자리", "3자리", "4자리"], symbol: "textformat.123"),
            ])]),
            .init(title: "삽입 크기", groups: [.init(title: "행과 열", items: [
                .button("insertRow", "행 삽입", "plus.rectangle"), .button("deleteRow", "행 삭제", "minus.rectangle"),
                .button("insertColumn", "열 삽입", "plus.rectangle.portrait"), .button("deleteColumn", "열 삭제", "minus.rectangle.portrait"),
                .button("autofit", "열 너비 자동", "arrow.left.and.right"), .field("rowHeight", "행 높이 (pt)", ["20", "24", "30", "40", "60"]),
            ]), .init(title: "시트 차트", items: [
                .button("newSheet", "시트 추가", "plus.square"), .button("renameSheet", "시트 이름", "pencil"),
                .menu("chart", "차트", ChartKind.allCases.map(\.title), symbol: "chart.bar"),
            ])]),
            .init(title: "데이터", groups: [.init(title: "계산과 정렬", items: [
                .button("sum", "자동 합계", "sum"), .button("sortUp", "오름차순", "arrow.up.square"), .button("sortDown", "내림차순", "arrow.down.square"),
                .button("fillDown", "아래로 채우기", "arrow.down.to.line"), .button("fillRight", "오른쪽 채우기", "arrow.right.to.line"), .button("series", "연속 데이터", "number"),
            ])]),
            .init(title: "보기", groups: [.init(title: "화면", items: [
                .toggle("freeze", "틀 고정", "pin"), .button("zoomOut", "축소", "minus.magnifyingglass"), .button("actual", "100%", "1.magnifyingglass"),
                .button("zoomIn", "확대", "plus.magnifyingglass"), .button("find", "찾기", "magnifyingglass"),
            ])]),
        ])
        ribbon?.onCommand = { [weak self] id, value, n in self?.command(id, value, n) }
        ribbon?.isOn = { [weak self] id in
            guard let self else { return false }
            let st = self.currentStyle
            switch id {
            case "bold": return st.bold
            case "italic": return st.italic
            case "underline": return st.underline
            case "left": return st.align == .left
            case "center": return st.align == .center
            case "right": return st.align == .right
            case "wrap": return st.wrap
            case "border": return st.border
            case "freeze": return self.sheet.frozenRows > 0 || self.sheet.frozenCols > 0
            default: return false
            }
        }
        ribbon?.currentValue = { [weak self] id in
            guard let self else { return nil }
            switch id {
            case "font": return self.currentStyle.fontName ?? "Apple SD Gothic Neo"
            case "size": return SheetValue.general(self.currentStyle.fontSize ?? 11)
            case "rowHeight": return SheetValue.general(self.sheet.height(self.grid?.cursor.row ?? 0))
            default: return nil
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

    private var currentStyle: CellStyle {
        guard let grid else { return CellStyle() }
        return sheet.cells[sheet.merge(containing: grid.cursor)?.start ?? grid.cursor]?.style ?? CellStyle()
    }

    private func restyle(_ name: String, _ change: (inout CellStyle) -> Void) {
        grid.commitEdit()
        let r = grid.expandedSelection
        let used = sheet.usedRange
        let count = (r.end.row - r.start.row + 1) * (r.end.col - r.start.col + 1)
        let end = count <= 100_000 ? r.end : CellRef(row: min(r.end.row, max(r.start.row, used?.end.row ?? r.start.row)), col: min(r.end.col, max(r.start.col, used?.end.col ?? r.start.col)))
        var changes: [(Worksheet, CellRef, SheetCell?)] = []
        for ref in CellRange(r.start, end).cells {
            var c = sheet.cells[ref] ?? SheetCell()
            change(&c.style)
            changes.append((sheet, ref, c))
        }
        doc.setCells(changes, actionName: name)
    }

    private func command(_ id: String, _ value: String, _ n: Int) {
        let source = ribbon?.control(id)
        switch id {
        case "cut": cutCells()
        case "copy": copyCells()
        case "paste": gridPaste()
        case "font": restyle("글꼴") { $0.fontName = value }
        case "size": if let v = Double(value), v.isFinite, v > 0 { restyle("글자 크기") { $0.fontSize = min(400, v) } }
        case "bold": let v = !currentStyle.bold; restyle("굵게") { $0.bold = v }
        case "italic": let v = !currentStyle.italic; restyle("기울임") { $0.italic = v }
        case "underline": let v = !currentStyle.underline; restyle("밑줄") { $0.underline = v }
        case "left": restyle("정렬") { $0.align = $0.align == .left ? .general : .left }
        case "center": restyle("정렬") { $0.align = $0.align == .center ? .general : .center }
        case "right": restyle("정렬") { $0.align = $0.align == .right ? .general : .right }
        case "wrap": let v = !currentStyle.wrap; restyle("줄 바꿈") { $0.wrap = v }
        case "merge": mergeCells()
        case "textColor":
            if n >= 0 && n < Palette.colors.count { let c = Palette.colors[n]; restyle("글자 색") { $0.color = c } }
            else { ColorPickerCoordinator.present(from: self, title: "글자 색", initial: currentStyle.color, source: source) { [weak self] c in self?.restyle("글자 색") { $0.color = c } } }
        case "fill":
            if n == 0 { restyle("채우기") { $0.fill = nil } }
            else if n - 1 < Palette.colors.count { let c = Palette.colors[n - 1]; restyle("채우기") { $0.fill = c == .white ? nil : c } }
            else { ColorPickerCoordinator.present(from: self, title: "채우기", initial: currentStyle.fill, source: source) { [weak self] c in self?.restyle("채우기") { $0.fill = c } } }
        case "border": let v = !currentStyle.border; restyle("테두리") { $0.border = v }
        case "clearFormat": restyle("서식 지우기") { $0 = CellStyle() }
        case "numberFormat":
            let codes = ["General", "#,##0", "#,##0.00", "\"₩\"#,##0", "0%", "0.00%", "yyyy-mm-dd", "yyyy\"년\" m\"월\" d\"일\""]
            let code = codes[max(0, min(codes.count - 1, n))]
            restyle("표시 형식") { $0.numberFormat = code == "General" ? nil : code }
        case "decimal": if n > 0 { restyle("소수 자릿수") { $0.numberFormat = n == 1 ? "#,##0" : "#,##0." + String(repeating: "0", count: n - 1) } }
        case "insertRow": structural("행 삽입", axis: .row, inserting: true)
        case "deleteRow": structural("행 삭제", axis: .row, inserting: false)
        case "insertColumn": structural("열 삽입", axis: .column, inserting: true)
        case "deleteColumn": structural("열 삭제", axis: .column, inserting: false)
        case "autofit": autoFitColumns()
        case "rowHeight":
            if let h = Double(value), h.isFinite, h > 0 {
                let rows = grid.selection
                var sizes = sheet.rowHeights
                for i in rows.start.row...min(rows.end.row, rows.start.row + 10_000) { sizes[i] = min(409, h) }
                doc.setDimensions(columns: sheet.columnWidths, rows: sizes, on: sheet)
            }
        case "newSheet": addSheet()
        case "renameSheet": renameSheet()
        case "chart": insertChart(ChartKind.allCases[max(0, min(ChartKind.allCases.count - 1, n))])
        case "sum": autoSum()
        case "sortUp": sort(ascending: true)
        case "sortDown": sort(ascending: false)
        case "fillDown": fill(down: true)
        case "fillRight": fill(down: false)
        case "series": fillSeries()
        case "freeze": toggleFreeze()
        case "zoomOut": grid.zoom /= 1.2
        case "zoomIn": grid.zoom *= 1.2
        case "actual": grid.zoom = 1
        case "find": showFind(nil)
        default: break
        }
        ribbon?.refresh()
    }

    private func mergeCells() {
        grid.commitEdit()
        var range = grid.selection
        var merges = sheet.merges
        if let old = sheet.merge(containing: range.start), old == range || range.start == range.end {
            merges.removeAll { $0 == old }
        } else {
            guard range.start != range.end else { return }
            range = grid.expandedSelection
            merges.removeAll { $0.start.row <= range.end.row && $0.end.row >= range.start.row && $0.start.col <= range.end.col && $0.end.col >= range.start.col }
            merges.append(range)
        }
        doc.setMerges(merges, on: sheet)
    }

    private func structural(_ name: String, axis: SheetStructuralEditing.Axis, inserting: Bool) {
        grid.commitEdit()
        do { try doc.structural(name, sheet: sheet, cell: grid.cursor, axis: axis, inserting: inserting) }
        catch { presentMessage(name, error.localizedDescription) }
    }

    private var workRange: CellRange? {
        let sel = grid.selection
        guard let used = sheet.usedRange else { return nil }
        if sel.start == sel.end { return used }
        let end = CellRef(row: min(sel.end.row, used.end.row), col: min(sel.end.col, used.end.col))
        return end.row >= sel.start.row && end.col >= sel.start.col ? CellRange(sel.start, end) : nil
    }

    private func sort(ascending: Bool) {
        grid.commitEdit()
        guard var range = workRange else { return }
        if grid.selection.start == grid.selection.end, range.end.row > range.start.row {
            let firstRow = (range.start.col...range.end.col).map { doc.engine.value(sheet, CellRef(row: range.start.row, col: $0)) }
            let isHeader = firstRow.allSatisfy { if case .string = $0 { return true }; return $0 == .empty } && firstRow.contains { $0 != .empty }
            if isHeader { range = CellRange(CellRef(row: range.start.row + 1, col: range.start.col), range.end) }
        }
        let key = min(max(grid.cursor.col, range.start.col), range.end.col)
        guard range.start.row < range.end.row else { return }
        let ws = sheet
        performDataEdit(ascending ? "오름차순 정렬" : "내림차순 정렬") {
            try SheetRangeEditing.sort(book: doc.book, sheet: ws, range: range, keyColumn: key, ascending: ascending, header: false)
        }
    }

    private func fill(down: Bool) {
        grid.commitEdit()
        let r = grid.selection
        guard down ? r.end.row > r.start.row : r.end.col > r.start.col else { return }
        let ws = sheet
        performDataEdit(down ? "아래로 채우기" : "오른쪽으로 채우기") {
            try SheetRangeEditing.fill(book: doc.book, sheet: ws, range: r, direction: down ? .down : .right)
        }
    }

    private func performDataEdit(_ name: String, change: () throws -> Void) {
        do { try doc.editData(on: sheet, named: name, change) }
        catch { presentMessage(name, error.localizedDescription) }
    }

    private func autoSum() {
        grid.commitEdit()
        let ref = grid.cursor
        var top = ref.row - 1
        while top >= 0, case .number = doc.engine.value(sheet, CellRef(row: top, col: ref.col)) { top -= 1 }
        guard top + 1 < ref.row else { grid.focus(); grid.beginEdit("=SUM()"); return }
        gridCommit(ref, input: "=SUM(\(CellRef(row: top + 1, col: ref.col).a1):\(CellRef(row: ref.row - 1, col: ref.col).a1))")
    }

    /// 연속 데이터: continues numeric steps (1,2 → 3,4…) or "항목1" trailing numbers.
    private func fillSeries() {
        grid.commitEdit()
        let r = grid.selection
        guard r.end.row > r.start.row else { fill(down: false); return }
        var changes: [(Worksheet, CellRef, SheetCell?)] = []
        for c in r.start.col...r.end.col {
            let a = sheet.cells[CellRef(row: r.start.row, col: c)]?.input ?? ""
            let b = sheet.cells[CellRef(row: r.start.row + 1, col: c)]?.input ?? ""
            if let x = Double(a) {
                let step = Double(b).map { $0 - x } ?? 1
                let start = Double(b) != nil ? 2 : 1
                guard r.start.row + start <= r.end.row else { continue }
                for (k, row) in ((r.start.row + start)...r.end.row).enumerated() {
                    var cell = sheet.cells[CellRef(row: r.start.row, col: c)] ?? SheetCell()
                    cell.input = SheetValue.general(x + step * Double(k + start))
                    changes.append((sheet, CellRef(row: row, col: c), cell))
                }
            } else if let m = a.range(of: "[0-9]+$", options: .regularExpression), let n = Int(a[m]) {
                let prefix = a[..<m.lowerBound]
                for (k, row) in ((r.start.row + 1)...r.end.row).enumerated() {
                    var cell = sheet.cells[CellRef(row: r.start.row, col: c)] ?? SheetCell()
                    cell.input = prefix + String(n + k + 1)
                    changes.append((sheet, CellRef(row: row, col: c), cell))
                }
            } else {
                for row in (r.start.row + 1)...r.end.row {
                    changes.append((sheet, CellRef(row: row, col: c), sheet.cells[CellRef(row: r.start.row, col: c)]))
                }
            }
        }
        if !changes.isEmpty { doc.setCells(changes, actionName: "연속 데이터 채우기") }
    }

    private func toggleFreeze() {
        if sheet.frozenRows > 0 || sheet.frozenCols > 0 { doc.setFrozen(rows: 0, cols: 0, on: sheet) }
        else {
            let c = grid.cursor
            doc.setFrozen(rows: c.row == 0 && c.col == 0 ? 1 : c.row, cols: c.col, on: sheet)
        }
    }

    private func autoFitColumns() {
        grid.commitEdit()
        let range = grid.selection
        var sizes = sheet.columnWidths
        for col in range.start.col...min(range.end.col, range.start.col + 1024) {
            var width: CGFloat = 24
            for (ref, cell) in sheet.cells where ref.col == col {
                let f = FontResolver.shared.font(name: cell.style.fontName ?? "Apple SD Gothic Neo", size: cell.style.fontSize ?? 11, bold: cell.style.bold, italic: cell.style.italic).font
                let text = cell.isFormula ? doc.engine.display(sheet, ref) : cell.input
                width = max(width, (text as NSString).size(withAttributes: [.font: f]).width + 16)
            }
            sizes[col] = Double(min(1000, width))
        }
        doc.setDimensions(columns: sizes, rows: sheet.rowHeights, on: sheet)
    }

    private func insertChart(_ kind: ChartKind) {
        grid.commitEdit()
        guard let range = workRange else { presentMessage("차트를 만들 수 없습니다", "숫자가 있는 범위를 먼저 선택하세요."); return }
        let x = Double(grid.x(ofCol: range.end.col + 1) - grid.x(ofCol: 0)) + 16
        let y = Double(grid.y(ofRow: range.start.row) - grid.y(ofRow: 0))
        var charts = sheet.charts
        charts.append(SheetChart(kind: kind, title: "", data: range, x: x, y: y))
        doc.setCharts(charts, on: sheet, name: "차트 삽입")
        grid.selectedChart = sheet.charts.count - 1
    }

    // MARK: Find

    override func showFind(_ sender: Any?) {
        promptText("찾기", text: lastSearch, placeholder: "값 또는 수식", confirm: "다음 찾기") { [weak self] value in
            guard let self, let value, !value.isEmpty else { return }
            self.lastSearch = value
            self.findNext(value, backwards: false)
        }
    }

    private func findNext(_ text: String, backwards: Bool) {
        let keys = sheet.cells.keys.sorted()
        let matches = keys.filter { k in
            let c = sheet.cells[k]!
            return c.input.localizedCaseInsensitiveContains(text) || doc.engine.display(sheet, k).localizedCaseInsensitiveContains(text)
        }
        guard !matches.isEmpty else { presentMessage("찾지 못했습니다", "‘\(text)’이(가) 이 시트에 없습니다."); return }
        let cur = grid.cursor
        let next = backwards ? (matches.last { $0 < cur } ?? matches.last!) : (matches.first { $0 > cur } ?? matches.first!)
        grid.select(next)
        grid.focus()
    }

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(title: "다음 찾기", action: #selector(keyFindNext), input: "g", modifierFlags: .command),
            UIKeyCommand(title: "이전 찾기", action: #selector(keyFindPrevious), input: "g", modifierFlags: [.command, .shift]),
            UIKeyCommand(title: "굵게", action: #selector(keyBold), input: "b", modifierFlags: .command),
            UIKeyCommand(title: "기울임", action: #selector(keyItalic), input: "i", modifierFlags: .command),
            UIKeyCommand(title: "밑줄", action: #selector(keyUnderline), input: "u", modifierFlags: .command),
            UIKeyCommand(title: "아래로 채우기", action: #selector(keyFillDown), input: "d", modifierFlags: .command),
            UIKeyCommand(title: "확대", action: #selector(keyZoomIn), input: "=", modifierFlags: .command),
            UIKeyCommand(title: "축소", action: #selector(keyZoomOut), input: "-", modifierFlags: .command),
        ]
    }
    @objc private func keyFindNext() { if !lastSearch.isEmpty { findNext(lastSearch, backwards: false) } }
    @objc private func keyFindPrevious() { if !lastSearch.isEmpty { findNext(lastSearch, backwards: true) } }
    @objc private func keyBold() { command("bold", "", 0) }
    @objc private func keyItalic() { command("italic", "", 0) }
    @objc private func keyUnderline() { command("underline", "", 0) }
    @objc private func keyFillDown() { command("fillDown", "", 0) }
    @objc private func keyZoomIn() { command("zoomIn", "", 0) }
    @objc private func keyZoomOut() { command("zoomOut", "", 0) }
}

/// 차트 설정: kind, title and data range; "차트 삭제" returns nil.
final class ChartEditorViewController: UIViewController {
    private var chart: SheetChart
    private let completion: (SheetChart?) -> Void
    private let kind = UISegmentedControl(items: ChartKind.allCases.map(\.title))
    private let titleField = UITextField()
    private let rangeField = UITextField()

    init(chart: SheetChart, completion: @escaping (SheetChart?) -> Void) {
        self.chart = chart
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "차트 설정"
        view.backgroundColor = HanXTheme.canvas
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.finish() })
        kind.selectedSegmentIndex = ChartKind.allCases.firstIndex(of: chart.kind) ?? 0
        for (f, p, t) in [(titleField, "차트 제목", chart.title), (rangeField, "데이터 범위 (예: A1:C10)", chart.data.a1)] {
            f.placeholder = p
            f.text = t
            f.borderStyle = .roundedRect
            f.autocorrectionType = .no
        }
        rangeField.autocapitalizationType = .allCharacters
        var del = UIButton.Configuration.bordered()
        del.title = "차트 삭제"
        del.baseForegroundColor = .systemRed
        let delete = UIButton(configuration: del, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true) { self?.completion(nil) }
        })
        let stack = UIStackView(arrangedSubviews: [kind, titleField, rangeField, delete])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
    }

    private func finish() {
        chart.kind = ChartKind.allCases[max(0, kind.selectedSegmentIndex)]
        chart.title = titleField.text ?? ""
        let parts = (rangeField.text ?? "").uppercased().split(separator: ":").compactMap { CellRef(a1: String($0)) }
        if parts.count == 2 { chart.data = CellRange(parts[0], parts[1]) }
        else if parts.count == 1 { chart.data = CellRange(parts[0], parts[0]) }
        let result = chart
        dismiss(animated: true) { self.completion(result) }
    }
}
