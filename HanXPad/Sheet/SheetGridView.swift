import UIKit
import GameController

protocol SheetGridDelegate: AnyObject {
    func gridSelectionChanged()
    func gridCommit(_ ref: CellRef, input: String)
    func gridClear(_ range: CellRange)
    func gridCopy(cut: Bool)
    func gridPaste()
    func gridChartsChanged(from old: [SheetChart], name: String)
    func gridEditChart(_ index: Int)
    func gridResized(columns: [Int: Double], rows: [Int: Double])
    func gridMenu(for range: CellRange) -> UIMenu
}

/// Spreadsheet grid for touch: a canvas pinned to the viewport draws only the
/// visible cells (sticky headers, frozen panes, merges, spills, charts) while
/// a scroll view provides momentum scrolling. Typing always goes to a cell
/// editor text field, so hardware-keyboard Korean input composes correctly.
final class SheetGridView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate, UIEditMenuInteractionDelegate {
    weak var delegate: SheetGridDelegate?
    var sheet: Worksheet { didSet { selectedChart = nil; reloadSize() } }
    let engine: FormulaEngine

    var anchor = CellRef(row: 0, col: 0)
    var cursor = CellRef(row: 0, col: 0)
    var selection: CellRange { CellRange(anchor, cursor) }
    var selectedChart: Int? { didSet { canvas.setNeedsDisplay() } }
    var zoom: CGFloat = 1 { didSet { zoom = max(0.4, min(3, zoom)); reloadSize() } }

    let scroll = UIScrollView()
    private let canvas = SheetCanvas()
    let editor = CellEditorField()
    private var editMenu: UIEditMenuInteraction?

    static let headerW: CGFloat = 46
    static let headerH: CGFloat = 24
    private var colEdges: [CGFloat] = []   // colEdges[c] = model x of column c's left edge
    private var rowEdges: [CGFloat] = []

    init(sheet: Worksheet, engine: FormulaEngine) {
        self.sheet = sheet
        self.engine = engine
        super.init(frame: .zero)
        backgroundColor = .white
        scroll.delegate = self
        scroll.showsHorizontalScrollIndicator = true
        scroll.showsVerticalScrollIndicator = true
        scroll.alwaysBounceVertical = true
        scroll.alwaysBounceHorizontal = true
        scroll.backgroundColor = .clear
        scroll.panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        canvas.grid = self
        canvas.isUserInteractionEnabled = false
        addSubview(canvas)
        addSubview(scroll)
        editor.grid = self
        addSubview(editor)

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        double.numberOfTapsRequired = 2
        tap.require(toFail: double)
        let long = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        long.minimumPressDuration = 0.35
        long.delegate = self
        let handle = UIPanGestureRecognizer(target: self, action: #selector(handlePanned(_:)))
        handle.delegate = self
        handle.maximumNumberOfTouches = 1
        handlePan = handle
        let pointer = UIPanGestureRecognizer(target: self, action: #selector(pointerPanned(_:)))
        pointer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        for g in [tap, double, long, handle, pointer, pinch] as [UIGestureRecognizer] { scroll.addGestureRecognizer(g) }
        scroll.panGestureRecognizer.require(toFail: handle)
        let menu = UIEditMenuInteraction(delegate: self)
        scroll.addInteraction(menu)
        editMenu = menu
        reloadSize()
    }

    required init?(coder: NSCoder) { fatalError() }

    private var handlePan: UIPanGestureRecognizer?

    override func layoutSubviews() {
        super.layoutSubviews()
        scroll.frame = bounds
        canvas.frame = bounds
        updateContentSize()
        positionEditor()
        canvas.setNeedsDisplay()
    }

    // MARK: Geometry (model points; display = model × zoom)

    var rowCount: Int { max(200, (sheet.usedRange?.end.row ?? 0) + 60, cursor.row + 30, chartExtent.row) }
    var colCount: Int { max(40, (sheet.usedRange?.end.col ?? 0) + 15, cursor.col + 10, chartExtent.col) }
    private var chartExtent: (row: Int, col: Int) {
        var r = 0, c = 0
        for ch in sheet.charts {
            r = max(r, Int((ch.y + ch.h) / Worksheet.defaultRowHeight) + 2)
            c = max(c, Int((ch.x + ch.w) / Worksheet.defaultColumnWidth) + 2)
        }
        return (r, c)
    }

    func reloadSize() {
        let cols = colCount, rows = rowCount
        colEdges = [SheetGridView.headerW]
        colEdges.reserveCapacity(cols + 1)
        for c in 0..<cols { colEdges.append(colEdges[c] + CGFloat(sheet.width(c))) }
        rowEdges = [SheetGridView.headerH]
        rowEdges.reserveCapacity(rows + 1)
        for r in 0..<rows { rowEdges.append(rowEdges[r] + CGFloat(sheet.height(r))) }
        updateContentSize()
        canvas.setNeedsDisplay()
        positionEditor()
    }

    private func updateContentSize() {
        let w = (colEdges.last ?? 0) - frozenWidth, h = (rowEdges.last ?? 0) - frozenHeight
        scroll.contentSize = CGSize(width: w * zoom, height: h * zoom)
    }

    func x(ofCol c: Int) -> CGFloat { c < colEdges.count ? colEdges[max(0, c)] : (colEdges.last ?? 0) + CGFloat(c - colEdges.count + 1) * CGFloat(Worksheet.defaultColumnWidth) }
    func y(ofRow r: Int) -> CGFloat { r < rowEdges.count ? rowEdges[max(0, r)] : (rowEdges.last ?? 0) + CGFloat(r - rowEdges.count + 1) * CGFloat(Worksheet.defaultRowHeight) }

    var frozenWidth: CGFloat { sheet.frozenCols > 0 ? x(ofCol: sheet.frozenCols) - SheetGridView.headerW : 0 }
    var frozenHeight: CGFloat { sheet.frozenRows > 0 ? y(ofRow: sheet.frozenRows) - SheetGridView.headerH : 0 }
    var scrollX: CGFloat { scroll.contentOffset.x / zoom }
    var scrollY: CGFloat { scroll.contentOffset.y / zoom }

    /// Model rectangle of a cell or merge, independent of scrolling.
    func modelRect(_ ref: CellRef) -> CGRect {
        if let m = sheet.merge(containing: ref) { return modelRect(of: m) }
        return CGRect(x: x(ofCol: ref.col), y: y(ofRow: ref.row), width: CGFloat(sheet.width(ref.col)), height: CGFloat(sheet.height(ref.row)))
    }

    func modelRect(of r: CellRange) -> CGRect {
        CGRect(x: x(ofCol: r.start.col), y: y(ofRow: r.start.row),
               width: x(ofCol: r.end.col + 1) - x(ofCol: r.start.col), height: y(ofRow: r.end.row + 1) - y(ofRow: r.start.row))
    }

    /// Display x for a model x belonging to a column (frozen columns do not scroll).
    func displayX(_ mx: CGFloat, col: Int) -> CGFloat { col < sheet.frozenCols ? mx : mx - scrollX }
    func displayY(_ my: CGFloat, row: Int) -> CGFloat { row < sheet.frozenRows ? my : my - scrollY }

    /// Display rectangle (model units) of a cell range, honouring frozen panes.
    func displayRect(of r: CellRange) -> CGRect {
        let x0 = displayX(x(ofCol: r.start.col), col: r.start.col), x1 = displayX(x(ofCol: r.end.col + 1), col: r.end.col)
        let y0 = displayY(y(ofRow: r.start.row), row: r.start.row), y1 = displayY(y(ofRow: r.end.row + 1), row: r.end.row)
        return CGRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }

    func chartModelRect(_ c: SheetChart) -> CGRect {
        CGRect(x: SheetGridView.headerW + CGFloat(c.x), y: SheetGridView.headerH + CGFloat(c.y), width: CGFloat(c.w), height: CGFloat(c.h))
    }
    func chartDisplayRect(_ c: SheetChart) -> CGRect { chartModelRect(c).offsetBy(dx: -scrollX, dy: -scrollY) }

    private func column(atModelX x: CGFloat) -> Int {
        var lo = 0, hi = colEdges.count - 1
        if x >= (colEdges.last ?? 0) { return colEdges.count - 1 + Int((x - (colEdges.last ?? 0)) / CGFloat(Worksheet.defaultColumnWidth)) }
        while lo < hi - 1 { let mid = (lo + hi) / 2; if colEdges[mid] <= x { lo = mid } else { hi = mid } }
        return max(0, lo)
    }

    private func row(atModelY y: CGFloat) -> Int {
        var lo = 0, hi = rowEdges.count - 1
        if y >= (rowEdges.last ?? 0) { return rowEdges.count - 1 + Int((y - (rowEdges.last ?? 0)) / CGFloat(Worksheet.defaultRowHeight)) }
        while lo < hi - 1 { let mid = (lo + hi) / 2; if rowEdges[mid] <= y { lo = mid } else { hi = mid } }
        return max(0, lo)
    }

    enum Hit { case corner, column(Int), row(Int), cell(CellRef) }

    /// What lies under a point in this view's coordinates.
    func hit(_ p: CGPoint) -> Hit {
        let d = CGPoint(x: p.x / zoom, y: p.y / zoom)
        let inColHeader = d.y < SheetGridView.headerH, inRowHeader = d.x < SheetGridView.headerW
        let mx = d.x < SheetGridView.headerW + frozenWidth ? d.x : d.x + scrollX
        let my = d.y < SheetGridView.headerH + frozenHeight ? d.y : d.y + scrollY
        if inColHeader && inRowHeader { return .corner }
        if inColHeader { return .column(column(atModelX: max(SheetGridView.headerW, mx))) }
        if inRowHeader { return .row(row(atModelY: max(SheetGridView.headerH, my))) }
        return .cell(CellRef(row: row(atModelY: my), col: column(atModelX: mx)))
    }

    func cell(at p: CGPoint) -> CellRef {
        switch hit(p) {
        case .cell(let r): return r
        case .column(let c): return CellRef(row: cursor.row, col: c)
        case .row(let r): return CellRef(row: r, col: cursor.col)
        case .corner: return CellRef(row: 0, col: 0)
        }
    }

    func chartIndex(at p: CGPoint) -> Int? {
        let d = CGPoint(x: p.x / zoom, y: p.y / zoom)
        guard d.x > SheetGridView.headerW + frozenWidth, d.y > SheetGridView.headerH + frozenHeight else { return nil }
        return sheet.charts.indices.reversed().first { chartDisplayRect(sheet.charts[$0]).contains(d) }
    }

    /// Visible model rows/cols of the scrolling region.
    func visibleRange() -> (rows: ClosedRange<Int>, cols: ClosedRange<Int>) {
        let w = bounds.width / zoom, h = bounds.height / zoom
        let left = SheetGridView.headerW + frozenWidth + scrollX, top = SheetGridView.headerH + frozenHeight + scrollY
        let c0 = max(sheet.frozenCols, column(atModelX: left)), c1 = max(c0, column(atModelX: left + w))
        let r0 = max(sheet.frozenRows, row(atModelY: top)), r1 = max(r0, row(atModelY: top + h))
        return (r0...min(r1, max(r0, rowEdges.count - 2)), c0...min(c1, max(c0, colEdges.count - 2)))
    }

    // MARK: Selection

    func select(_ ref: CellRef, extend: Bool = false) {
        commitEdit()
        let r = CellRef(row: max(0, min(ref.row, 1_048_575)), col: max(0, min(ref.col, 16_383)))
        cursor = r
        if !extend { anchor = r }
        selectedChart = nil
        if r.row >= rowEdges.count - 10 || r.col >= colEdges.count - 5 { reloadSize() }
        scrollToVisible(r)
        canvas.setNeedsDisplay()
        positionEditor()
        delegate?.gridSelectionChanged()
    }

    func selectRange(_ range: CellRange) {
        commitEdit()
        anchor = range.start
        cursor = range.end
        canvas.setNeedsDisplay()
        positionEditor()
        delegate?.gridSelectionChanged()
    }

    func move(rows dr: Int, cols dc: Int, extend: Bool) {
        var target = cursor
        // Step out of a merge as a unit.
        if let m = sheet.merge(containing: cursor) {
            if dr > 0 { target.row = m.end.row }
            if dc > 0 { target.col = m.end.col }
            if dr < 0 { target.row = m.start.row }
            if dc < 0 { target.col = m.start.col }
        }
        target = CellRef(row: max(0, target.row + dr), col: max(0, target.col + dc))
        select(target, extend: extend)
    }

    func scrollToVisible(_ ref: CellRef) {
        let m = modelRect(ref)
        var offset = scroll.contentOffset
        let viewW = bounds.width / zoom, viewH = bounds.height / zoom
        let left = SheetGridView.headerW + frozenWidth
        let top = SheetGridView.headerH + frozenHeight
        if ref.col >= sheet.frozenCols {
            if m.minX - scrollX < left { offset.x = (m.minX - left) * zoom }
            else if m.maxX - scrollX > viewW { offset.x = (m.maxX - viewW + 4) * zoom }
        }
        if ref.row >= sheet.frozenRows {
            if m.minY - scrollY < top { offset.y = (m.minY - top) * zoom }
            else if m.maxY - scrollY > viewH { offset.y = (m.maxY - viewH + 4) * zoom }
        }
        offset.x = max(0, min(offset.x, max(0, scroll.contentSize.width - bounds.width + 40)))
        offset.y = max(0, min(offset.y, max(0, scroll.contentSize.height - bounds.height + 40)))
        if offset != scroll.contentOffset { scroll.setContentOffset(offset, animated: false) }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        canvas.setNeedsDisplay()
        positionEditor()
    }

    // MARK: Editing

    var isEditing: Bool { editor.state != .ready }

    func positionEditor() {
        let ref = sheet.merge(containing: cursor)?.start ?? cursor
        let target = sheet.merge(containing: ref) ?? CellRange(ref, ref)
        let r = displayRect(of: target)
        var frame = CGRect(x: r.minX * zoom, y: r.minY * zoom, width: r.width * zoom, height: r.height * zoom)
        if editor.state != .ready {
            let natural = editor.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: frame.height)).width + 12
            frame.size.width = max(frame.width, min(natural, bounds.width - frame.minX))
        }
        editor.frame = frame.integral
        editor.font = editorFont(ref)
    }

    private func editorFont(_ ref: CellRef) -> UIFont {
        let st = sheet.cells[ref]?.style ?? CellStyle()
        let size = min(30, st.fontSize ?? 11) * zoom
        return FontResolver.shared.font(name: st.fontName ?? "Apple SD Gothic Neo", size: Double(size), bold: st.bold, italic: st.italic).font
    }

    /// Starts editing the cursor cell (double tap, F2, formula entry).
    func beginEdit(_ text: String? = nil, typed: Bool = false) {
        let ref = sheet.merge(containing: cursor)?.start ?? cursor
        editor.begin(text ?? sheet.cells[ref]?.input ?? "", typed: typed)
        positionEditor()
        canvas.setNeedsDisplay()
    }

    func commitEdit() {
        guard editor.state != .ready else { return }
        let ref = sheet.merge(containing: cursor)?.start ?? cursor
        let text = editor.text ?? ""
        editor.reset()
        canvas.setNeedsDisplay()
        delegate?.gridCommit(ref, input: text)
    }

    func cancelEdit() {
        editor.reset()
        canvas.setNeedsDisplay()
        delegate?.gridSelectionChanged()
    }

    var editingRef: CellRef? { editor.state == .ready ? nil : (sheet.merge(containing: cursor)?.start ?? cursor) }

    func focus() { if !editor.isFirstResponder { editor.becomeFirstResponder() } }

    func refresh() {
        reloadSize()
        canvas.setNeedsDisplay()
    }

    // MARK: Gestures

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        let p = g.location(in: self)
        focus()
        let extend = g.modifierFlags.contains(.shift)
        if let i = chartIndex(at: p) {
            commitEdit()
            selectedChart = i
            delegate?.gridSelectionChanged()
            return
        }
        switch hit(p) {
        case .corner:
            selectRange(CellRange(CellRef(row: 0, col: 0), CellRef(row: max(0, (sheet.usedRange?.end.row ?? 0)), col: max(0, (sheet.usedRange?.end.col ?? 0)))))
        case .column(let c):
            commitEdit()
            anchor = CellRef(row: 0, col: extend ? anchor.col : c)
            cursor = CellRef(row: max(rowCount - 1, sheet.usedRange?.end.row ?? 0), col: c)
            if !extend { anchor.col = c }
            canvas.setNeedsDisplay(); positionEditor(); delegate?.gridSelectionChanged()
        case .row(let r):
            commitEdit()
            anchor = CellRef(row: extend ? anchor.row : r, col: 0)
            cursor = CellRef(row: r, col: max(colCount - 1, sheet.usedRange?.end.col ?? 0))
            canvas.setNeedsDisplay(); positionEditor(); delegate?.gridSelectionChanged()
        case .cell(let ref):
            let wasSelected = selection.contains(ref) && !isEditing
            if wasSelected && !extend && selection.start == selection.end && ref == cursor {
                editMenu?.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: g.location(in: scroll)))
                return
            }
            select(ref, extend: extend)
        }
    }

    @objc private func doubleTapped(_ g: UITapGestureRecognizer) {
        let p = g.location(in: self)
        if let i = chartIndex(at: p) { delegate?.gridEditChart(i); return }
        guard case .cell(let ref) = hit(p) else { return }
        if ref != cursor { select(ref) }
        focus()
        beginEdit()
    }

    private var dragMode: DragMode = .none
    private enum DragMode { case none, extend, moveChart(Int, SheetChart, CGPoint), resizeChart(Int, SheetChart, CGPoint), resizeColumn(Int, CGFloat, Double), resizeRow(Int, CGFloat, Double) }

    @objc private func longPressed(_ g: UILongPressGestureRecognizer) {
        let p = g.location(in: self)
        switch g.state {
        case .began:
            commitEdit()
            if case .cell(let ref) = hit(p) {
                if !selection.contains(ref) { select(ref) }
                anchor = selection.start == cursor ? selection.end : selection.start
                if selection.start == selection.end { anchor = ref }
                cursor = ref
                dragMode = .extend
            }
        case .changed:
            if case .extend = dragMode, case .cell(let ref) = hit(p) {
                cursor = ref
                autoscroll(near: p)
                canvas.setNeedsDisplay()
                positionEditor()
            }
        case .ended:
            if case .extend = dragMode {
                dragMode = .none
                delegate?.gridSelectionChanged()
                editMenu?.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: g.location(in: scroll)))
            }
        default: dragMode = .none
        }
    }

    private func autoscroll(near p: CGPoint) {
        var offset = scroll.contentOffset
        let margin: CGFloat = 40, step: CGFloat = 24
        if p.x > bounds.width - margin { offset.x += step } else if p.x < (SheetGridView.headerW + frozenWidth) * zoom + margin { offset.x -= step }
        if p.y > bounds.height - margin { offset.y += step } else if p.y < (SheetGridView.headerH + frozenHeight) * zoom + margin { offset.y -= step }
        offset.x = max(0, min(offset.x, max(0, scroll.contentSize.width - bounds.width)))
        offset.y = max(0, min(offset.y, max(0, scroll.contentSize.height - bounds.height)))
        scroll.contentOffset = offset
    }

    /// Bottom-right selection handle (display points).
    private var handleCenter: CGPoint {
        let r = displayRect(of: selection)
        return CGPoint(x: r.maxX * zoom, y: r.maxY * zoom)
    }

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard g === handlePan else { return super.gestureRecognizerShouldBegin(g) }
        let p = g.location(in: self)
        if hypot(p.x - handleCenter.x, p.y - handleCenter.y) < 22 { return true }
        if let i = selectedChart, sheet.charts.indices.contains(i) {
            let r = chartDisplayRect(sheet.charts[i])
            let corner = CGPoint(x: r.maxX * zoom, y: r.maxY * zoom)
            if hypot(p.x - corner.x, p.y - corner.y) < 26 { return true }
            if CGRect(x: r.minX * zoom, y: r.minY * zoom, width: r.width * zoom, height: r.height * zoom).contains(p) { return true }
        }
        let d = CGPoint(x: p.x / zoom, y: p.y / zoom)
        if d.y < SheetGridView.headerH || d.x < SheetGridView.headerW { return boundary(at: p) != nil }
        return false
    }

    /// A column or row border under the finger in the headers.
    private func boundary(at p: CGPoint) -> (column: Int?, row: Int?)? {
        let d = CGPoint(x: p.x / zoom, y: p.y / zoom)
        if d.y < SheetGridView.headerH, d.x > SheetGridView.headerW {
            let mx = d.x < SheetGridView.headerW + frozenWidth ? d.x : d.x + scrollX
            let c = column(atModelX: mx)
            for candidate in [c, c - 1] where candidate >= 0 && abs(x(ofCol: candidate + 1) - mx) * zoom < 12 { return (candidate, nil) }
        }
        if d.x < SheetGridView.headerW, d.y > SheetGridView.headerH {
            let my = d.y < SheetGridView.headerH + frozenHeight ? d.y : d.y + scrollY
            let r = row(atModelY: my)
            for candidate in [r, r - 1] where candidate >= 0 && abs(y(ofRow: candidate + 1) - my) * zoom < 10 { return (nil, candidate) }
        }
        return nil
    }

    @objc private func handlePanned(_ g: UIPanGestureRecognizer) {
        let p = g.location(in: self)
        switch g.state {
        case .began:
            commitEdit()
            if hypot(p.x - handleCenter.x, p.y - handleCenter.y) < 22 && selectedChart == nil { dragMode = .extend; return }
            if let i = selectedChart, sheet.charts.indices.contains(i) {
                let chart = sheet.charts[i]
                let r = chartDisplayRect(chart)
                let corner = CGPoint(x: r.maxX * zoom, y: r.maxY * zoom)
                dragMode = hypot(p.x - corner.x, p.y - corner.y) < 26 ? .resizeChart(i, chart, p) : .moveChart(i, chart, p)
                return
            }
            if let b = boundary(at: p) {
                if let c = b.column { dragMode = .resizeColumn(c, p.x, sheet.width(c)) }
                else if let r = b.row { dragMode = .resizeRow(r, p.y, sheet.height(r)) }
            }
        case .changed:
            switch dragMode {
            case .extend:
                cursor = cell(at: p)
                autoscroll(near: p)
                canvas.setNeedsDisplay()
            case .moveChart(let i, let original, let start):
                var c = original
                c.x = max(0, original.x + Double((p.x - start.x) / zoom))
                c.y = max(0, original.y + Double((p.y - start.y) / zoom))
                sheet.charts[i] = c
                canvas.setNeedsDisplay()
            case .resizeChart(let i, let original, let start):
                var c = original
                c.w = max(120, original.w + Double((p.x - start.x) / zoom))
                c.h = max(90, original.h + Double((p.y - start.y) / zoom))
                sheet.charts[i] = c
                canvas.setNeedsDisplay()
            case .resizeColumn(let c, let x0, let w0):
                sheet.columnWidths[c] = max(12, w0 + Double((p.x - x0) / zoom))
                reloadSize()
            case .resizeRow(let r, let y0, let h0):
                sheet.rowHeights[r] = max(8, h0 + Double((p.y - y0) / zoom))
                reloadSize()
            case .none: break
            }
            positionEditor()
        case .ended, .cancelled:
            switch dragMode {
            case .extend: delegate?.gridSelectionChanged()
            case .moveChart(let i, let original, _), .resizeChart(let i, let original, _):
                var old = sheet.charts
                if old.indices.contains(i) { old[i] = original }
                delegate?.gridChartsChanged(from: old, name: "차트 이동")
            case .resizeColumn(let c, _, let w0):
                var columns = sheet.columnWidths
                let new = sheet.width(c)
                columns[c] = w0
                sheet.columnWidths = columns
                columns[c] = new
                delegate?.gridResized(columns: columns, rows: sheet.rowHeights)
            case .resizeRow(let r, _, let h0):
                var rows = sheet.rowHeights
                let new = sheet.height(r)
                rows[r] = h0
                sheet.rowHeights = rows
                rows[r] = new
                delegate?.gridResized(columns: sheet.columnWidths, rows: rows)
            case .none: break
            }
            dragMode = .none
        default: dragMode = .none
        }
    }

    @objc private func pointerPanned(_ g: UIPanGestureRecognizer) {
        let p = g.location(in: self)
        switch g.state {
        case .began:
            focus()
            if case .cell(let ref) = hit(p) { select(ref, extend: g.modifierFlags.contains(.shift)) }
        case .changed:
            if case .cell(let ref) = hit(p) { cursor = ref; autoscroll(near: p); canvas.setNeedsDisplay(); positionEditor() }
        case .ended: delegate?.gridSelectionChanged()
        default: break
        }
    }

    private var pinchStart: CGFloat = 1
    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began: pinchStart = zoom
        case .changed:
            let focusPoint = g.location(in: self)
            let modelFocus = CGPoint(x: focusPoint.x / zoom + scrollX, y: focusPoint.y / zoom + scrollY)
            zoom = pinchStart * g.scale
            var offset = CGPoint(x: (modelFocus.x - focusPoint.x / zoom) * zoom, y: (modelFocus.y - focusPoint.y / zoom) * zoom)
            offset.x = max(0, min(offset.x, max(0, scroll.contentSize.width - bounds.width)))
            offset.y = max(0, min(offset.y, max(0, scroll.contentSize.height - bounds.height)))
            scroll.contentOffset = offset
        default: break
        }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { false }

    // MARK: Edit menu

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration, suggestedActions: [UIMenuElement]) -> UIMenu? {
        delegate?.gridMenu(for: selection)
    }

    // MARK: Keyboard (called by the cell editor in ready state)

    func handleKey(_ key: UIKey) -> Bool {
        let shift = key.modifierFlags.contains(.shift)
        let command = key.modifierFlags.contains(.command)
        switch key.keyCode {
        case .keyboardUpArrow: command ? select(CellRef(row: 0, col: cursor.col), extend: shift) : move(rows: -1, cols: 0, extend: shift); return true
        case .keyboardDownArrow: command ? select(CellRef(row: max(0, sheet.usedRange?.end.row ?? 0), col: cursor.col), extend: shift) : move(rows: 1, cols: 0, extend: shift); return true
        case .keyboardLeftArrow: command ? select(CellRef(row: cursor.row, col: 0), extend: shift) : move(rows: 0, cols: -1, extend: shift); return true
        case .keyboardRightArrow: command ? select(CellRef(row: cursor.row, col: max(0, sheet.usedRange?.end.col ?? 0)), extend: shift) : move(rows: 0, cols: 1, extend: shift); return true
        case .keyboardTab: move(rows: 0, cols: shift ? -1 : 1, extend: false); return true
        case .keyboardReturnOrEnter: move(rows: shift ? -1 : 1, cols: 0, extend: false); return true
        case .keyboardDeleteOrBackspace, .keyboardDeleteForward:
            if let i = selectedChart {
                var charts = sheet.charts
                let old = charts
                charts.remove(at: i)
                sheet.charts = charts
                selectedChart = nil
                delegate?.gridChartsChanged(from: old, name: "차트 삭제")
            } else {
                delegate?.gridClear(selection)
            }
            return true
        case .keyboardF2: beginEdit(); return true
        case .keyboardPageDown: move(rows: max(1, Int(bounds.height / zoom / 22)), cols: 0, extend: shift); return true
        case .keyboardPageUp: move(rows: -max(1, Int(bounds.height / zoom / 22)), cols: 0, extend: shift); return true
        case .keyboardHome: select(CellRef(row: cursor.row, col: 0), extend: shift); return true
        case .keyboardEscape: selectedChart = nil; anchor = cursor; canvas.setNeedsDisplay(); return true
        default: return false
        }
    }

    // MARK: Drawing (called by the canvas)

    fileprivate func drawGrid(in g: CGContext) {
        let gridColor = UIColor(white: 0.86, alpha: 1)
        let w = bounds.width / zoom, h = bounds.height / zoom
        g.saveGState()
        g.scaleBy(x: zoom, y: zoom)
        UIColor.white.setFill()
        g.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let hw = SheetGridView.headerW, hh = SheetGridView.headerH
        let fw = frozenWidth, fh = frozenHeight
        let vis = visibleRange()
        let frozenRows = sheet.frozenRows > 0 ? 0...(sheet.frozenRows - 1) : nil
        let frozenCols = sheet.frozenCols > 0 ? 0...(sheet.frozenCols - 1) : nil

        func region(clip: CGRect, dx: CGFloat, dy: CGFloat, rows: ClosedRange<Int>, cols: ClosedRange<Int>, charts: Bool) {
            g.saveGState()
            g.clip(to: clip)
            g.translateBy(x: -dx, y: -dy)
            drawCells(rows: rows, cols: cols, grid: gridColor, in: g)
            if charts { drawCharts(in: g) }
            g.restoreGState()
        }
        region(clip: CGRect(x: hw + fw, y: hh + fh, width: w, height: h), dx: scrollX, dy: scrollY, rows: vis.rows, cols: vis.cols, charts: true)
        if let fr = frozenRows { region(clip: CGRect(x: hw + fw, y: hh, width: w, height: fh), dx: scrollX, dy: 0, rows: fr, cols: vis.cols, charts: false) }
        if let fc = frozenCols { region(clip: CGRect(x: hw, y: hh + fh, width: fw, height: h), dx: 0, dy: scrollY, rows: vis.rows, cols: fc, charts: false) }
        if let fr = frozenRows, let fc = frozenCols { region(clip: CGRect(x: hw, y: hh, width: fw, height: fh), dx: 0, dy: 0, rows: fr, cols: fc, charts: false) }

        drawSelection(in: g)
        drawHeaders(in: g, visible: vis, width: w, height: h)
        if fh > 0 || fw > 0 {
            g.setStrokeColor(UIColor(white: 0.5, alpha: 1).cgColor)
            g.setLineWidth(1.2)
            if fh > 0 { g.move(to: CGPoint(x: 0, y: hh + fh)); g.addLine(to: CGPoint(x: w, y: hh + fh)) }
            if fw > 0 { g.move(to: CGPoint(x: hw + fw, y: 0)); g.addLine(to: CGPoint(x: hw + fw, y: h)) }
            g.strokePath()
        }
        g.restoreGState()
    }

    /// Print/PDF: draws the cells and charts inside `rect` (model space) at the origin.
    func drawForPrint(_ rect: CGRect, in g: CGContext) {
        g.saveGState()
        g.translateBy(x: -rect.minX, y: -rect.minY)
        g.clip(to: rect)
        let rows = row(atModelY: rect.minY + 0.5)...max(row(atModelY: rect.minY + 0.5), row(atModelY: rect.maxY - 0.5))
        let cols = column(atModelX: rect.minX + 0.5)...max(column(atModelX: rect.minX + 0.5), column(atModelX: rect.maxX - 0.5))
        drawCells(rows: rows, cols: cols, grid: UIColor(white: 0.85, alpha: 1), in: g)
        drawCharts(in: g)
        g.restoreGState()
    }

    /// Model extent of the used cells and charts (for printing).
    var printExtent: CGRect? {
        var full = sheet.usedRange.map { modelRect(of: CellRange(CellRef(row: 0, col: 0), $0.end)) }
        for c in sheet.charts {
            let r = chartModelRect(c)
            full = full.map { $0.union(r) } ?? r.union(CGRect(x: SheetGridView.headerW, y: SheetGridView.headerH, width: 0, height: 0))
        }
        return full
    }

    /// Cell edges inside a span, for page breaks on cell boundaries.
    func columnEdges() -> [CGFloat] { colEdges }
    func rowEdgesList() -> [CGFloat] { rowEdges }

    private func drawCells(rows: ClosedRange<Int>, cols: ClosedRange<Int>, grid: UIColor, in g: CGContext) {
        // Grid lines first, then fills and text.
        g.setStrokeColor(grid.cgColor)
        g.setLineWidth(0.5)
        let x0 = x(ofCol: cols.lowerBound), x1 = x(ofCol: cols.upperBound + 1)
        let y0 = y(ofRow: rows.lowerBound), y1 = y(ofRow: rows.upperBound + 1)
        for c in cols.lowerBound...(cols.upperBound + 1) { let x = self.x(ofCol: c); g.move(to: CGPoint(x: x, y: y0)); g.addLine(to: CGPoint(x: x, y: y1)) }
        for r in rows.lowerBound...(rows.upperBound + 1) { let y = self.y(ofRow: r); g.move(to: CGPoint(x: x0, y: y)); g.addLine(to: CGPoint(x: x1, y: y)) }
        g.strokePath()
        var drawnMerges = Set<CellRange>()
        let editing = editingRef
        // Merges whose origin is outside the visible range still need drawing.
        for m in sheet.merges where m.start.row <= rows.upperBound && m.end.row >= rows.lowerBound && m.start.col <= cols.upperBound && m.end.col >= cols.lowerBound {
            drawnMerges.insert(m)
            let area = modelRect(of: m)
            UIColor.white.setFill(); g.fill(area.insetBy(dx: 0.3, dy: 0.3))
            let cell = sheet.cells[m.start]
            if let fill = cell?.style.fill { g.setFillColor(fill.cgColor); g.fill(area) }
            g.setStrokeColor(grid.cgColor); g.stroke(area)
            if cell?.style.border == true { g.setStrokeColor(UIColor.black.cgColor); g.setLineWidth(0.8); g.stroke(area); g.setLineWidth(0.5) }
            if editing != m.start, let cell, !cell.input.isEmpty { drawText(cell, ref: m.start, in: area, cols: cols) }
        }
        for r in rows {
            for c in cols {
                let ref = CellRef(row: r, col: c)
                if let m = sheet.merge(containing: ref), drawnMerges.contains(m) { continue }
                let area = modelRect(ref)
                let cell = sheet.cells[ref]
                if let fill = cell?.style.fill { g.setFillColor(fill.cgColor); g.fill(area) }
                if cell?.style.border == true { g.setStrokeColor(UIColor.black.cgColor); g.setLineWidth(0.8); g.stroke(area); g.setLineWidth(0.5) }
                guard editing != ref else { continue }
                if let cell, !cell.input.isEmpty { drawText(cell, ref: ref, in: area, cols: cols) }
                else if engine.value(sheet, ref) != .empty { drawText(cell ?? SheetCell(), ref: ref, in: area, cols: cols) }
            }
        }
    }

    private func drawText(_ cell: SheetCell, ref: CellRef, in area: CGRect, cols: ClosedRange<Int>) {
        let value = engine.value(sheet, ref)
        let text = engine.display(sheet, ref)
        guard !text.isEmpty else { return }
        let st = cell.style
        let font = FontResolver.shared.font(name: st.fontName ?? "Apple SD Gothic Neo", size: min(30, st.fontSize ?? 11), bold: st.bold, italic: st.italic).font
        var color = st.color?.uiColor ?? .black
        if value.isError { color = .systemRed }
        let para = NSMutableParagraphStyle()
        let isNumber: Bool = { if case .number = value { return true }; return false }()
        let isBool: Bool = { if case .bool = value { return true }; return false }()
        switch st.align {
        case .left: para.alignment = .left
        case .center: para.alignment = .center
        case .right: para.alignment = .right
        case .general: para.alignment = isNumber || value.isError ? .right : isBool ? .center : .left
        }
        para.lineBreakMode = st.wrap ? .byWordWrapping : .byClipping
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: para]
        if st.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        let s = NSAttributedString(string: text, attributes: attrs)
        let inner = area.insetBy(dx: 3, dy: 1)
        let h = st.wrap ? s.boundingRect(with: CGSize(width: inner.width, height: 1e6), options: [.usesLineFragmentOrigin], context: nil).height : font.lineHeight
        let y = inner.minY + max(0, (inner.height - h) / 2)
        guard let g = UIGraphicsGetCurrentContext() else { return }
        g.saveGState()
        // Text overflows into empty right-hand neighbours, like Excel.
        var clip = inner
        let width = s.size().width
        if !st.wrap && !isNumber && para.alignment == .left {
            var c = ref.col + 1
            while clip.width < width + 6, c < ref.col + 20, sheet.cells[CellRef(row: ref.row, col: c)]?.input.isEmpty ?? true,
                  engine.value(sheet, CellRef(row: ref.row, col: c)) == .empty {
                clip.size.width += CGFloat(sheet.width(c)); c += 1
            }
        }
        g.clip(to: clip)
        s.draw(with: CGRect(x: inner.minX, y: y, width: st.wrap ? inner.width : max(inner.width, clip.width), height: inner.maxY - y),
               options: [.usesLineFragmentOrigin], context: nil)
        g.restoreGState()
    }

    private func drawCharts(in g: CGContext) {
        for (i, ch) in sheet.charts.enumerated() {
            let r = chartModelRect(ch)
            ChartRenderer.draw(ch, ws: sheet, engine: engine, in: r, selected: i == selectedChart)
            if i == selectedChart {
                g.setFillColor(UIColor.systemBlue.cgColor)
                g.fillEllipse(in: CGRect(x: r.maxX - 7, y: r.maxY - 7, width: 14, height: 14))
            }
        }
    }

    private func drawSelection(in g: CGContext) {
        let hw = SheetGridView.headerW, hh = SheetGridView.headerH
        g.saveGState()
        g.clip(to: CGRect(x: hw, y: hh, width: bounds.width / zoom, height: bounds.height / zoom))
        let accent = UIColor.systemBlue
        if let spill = engine.spillRange(sheet, cursor), spill.start != spill.end {
            g.setStrokeColor(accent.withAlphaComponent(0.6).cgColor)
            g.setLineDash(phase: 0, lengths: [3, 2])
            g.setLineWidth(1)
            g.stroke(displayRect(of: spill).insetBy(dx: 1, dy: 1))
            g.setLineDash(phase: 0, lengths: [])
        }
        if selectedChart == nil {
            let r = displayRect(of: expandedSelection)
            if selection.start != selection.end {
                g.setFillColor(accent.withAlphaComponent(0.1).cgColor)
                g.fill(r)
            }
            g.setStrokeColor(accent.cgColor)
            g.setLineWidth(2)
            g.stroke(r)
            let cur = displayRect(of: sheet.merge(containing: cursor) ?? CellRange(cursor, cursor))
            g.setLineWidth(selection.start == selection.end ? 2 : 1)
            g.stroke(cur.insetBy(dx: 1, dy: 1))
            // Fill/extend handle.
            g.setFillColor(UIColor.white.cgColor)
            g.fillEllipse(in: CGRect(x: r.maxX - 5, y: r.maxY - 5, width: 10, height: 10))
            g.setStrokeColor(accent.cgColor)
            g.setLineWidth(1.5)
            g.strokeEllipse(in: CGRect(x: r.maxX - 5, y: r.maxY - 5, width: 10, height: 10))
        }
        g.restoreGState()
    }

    /// Selection grown to whole merges it touches.
    var expandedSelection: CellRange {
        var r = selection
        var changed = true
        while changed {
            changed = false
            for m in sheet.merges where m.start.row <= r.end.row && m.end.row >= r.start.row && m.start.col <= r.end.col && m.end.col >= r.start.col {
                let bigger = CellRange(CellRef(row: min(r.start.row, m.start.row), col: min(r.start.col, m.start.col)),
                                       CellRef(row: max(r.end.row, m.end.row), col: max(r.end.col, m.end.col)))
                if bigger != r { r = bigger; changed = true }
            }
        }
        return r
    }

    private func drawHeaders(in g: CGContext, visible: (rows: ClosedRange<Int>, cols: ClosedRange<Int>), width w: CGFloat, height h: CGFloat) {
        let hw = SheetGridView.headerW, hh = SheetGridView.headerH
        let bg = UIColor(white: 0.955, alpha: 1), selected = UIColor.systemBlue.withAlphaComponent(0.18)
        let font = UIFont.systemFont(ofSize: 11)
        let para = NSMutableParagraphStyle(); para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.darkGray, .paragraphStyle: para]
        let sel = expandedSelection
        g.setFillColor(bg.cgColor)
        g.fill(CGRect(x: 0, y: 0, width: w, height: hh))
        g.fill(CGRect(x: 0, y: 0, width: hw, height: h))
        var cols = Array(visible.cols)
        if sheet.frozenCols > 0 { cols = Array(0..<sheet.frozenCols) + cols }
        var rows = Array(visible.rows)
        if sheet.frozenRows > 0 { rows = Array(0..<sheet.frozenRows) + rows }
        g.saveGState()
        g.clip(to: CGRect(x: hw, y: 0, width: w, height: hh))
        for c in cols {
            let x0 = displayX(x(ofCol: c), col: c), x1 = x0 + CGFloat(sheet.width(c))
            if c < sheet.frozenCols || x1 > hw + frozenWidth {
                let r = CGRect(x: x0, y: 0, width: x1 - x0, height: hh)
                if c >= sel.start.col && c <= sel.end.col { g.setFillColor(selected.cgColor); g.fill(r) }
                (CellRef.columnName(c) as NSString).draw(in: CGRect(x: r.minX, y: 5, width: r.width, height: hh - 5), withAttributes: attrs)
                g.setStrokeColor(UIColor(white: 0.8, alpha: 1).cgColor); g.setLineWidth(0.5)
                g.move(to: CGPoint(x: x1, y: 0)); g.addLine(to: CGPoint(x: x1, y: hh)); g.strokePath()
            }
        }
        g.restoreGState()
        g.saveGState()
        g.clip(to: CGRect(x: 0, y: hh, width: hw, height: h))
        for r in rows {
            let y0 = displayY(y(ofRow: r), row: r), y1 = y0 + CGFloat(sheet.height(r))
            if r < sheet.frozenRows || y1 > hh + frozenHeight {
                let rr = CGRect(x: 0, y: y0, width: hw, height: y1 - y0)
                if r >= sel.start.row && r <= sel.end.row { g.setFillColor(selected.cgColor); g.fill(rr) }
                ("\(r + 1)" as NSString).draw(in: CGRect(x: 0, y: rr.midY - 7, width: hw, height: 14), withAttributes: attrs)
                g.setStrokeColor(UIColor(white: 0.8, alpha: 1).cgColor); g.setLineWidth(0.5)
                g.move(to: CGPoint(x: 0, y: y1)); g.addLine(to: CGPoint(x: hw, y: y1)); g.strokePath()
            }
        }
        g.restoreGState()
        g.setStrokeColor(UIColor(white: 0.72, alpha: 1).cgColor)
        g.setLineWidth(1)
        g.move(to: CGPoint(x: 0, y: hh)); g.addLine(to: CGPoint(x: w, y: hh))
        g.move(to: CGPoint(x: hw, y: 0)); g.addLine(to: CGPoint(x: hw, y: h))
        g.strokePath()
    }
}

/// Draws the visible part of the grid; sits under the scroll view.
private final class SheetCanvas: UIView {
    weak var grid: SheetGridView?
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .white
        isOpaque = true
        contentMode = .redraw
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ rect: CGRect) {
        guard let g = UIGraphicsGetCurrentContext() else { return }
        grid?.drawGrid(in: g)
    }
}

/// The cell editor. In the "ready" state it is invisible but first responder,
/// so arrow keys navigate and the first typed character (including Korean
/// IME composition) starts editing in place, as in Excel.
final class CellEditorField: UITextField, UITextFieldDelegate {
    enum State { case ready, typing, editing }
    weak var grid: SheetGridView?
    private(set) var state: State = .ready
    private let emptyInput = UIView(frame: .zero)

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        autocorrectionType = .no
        autocapitalizationType = .none
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        borderStyle = .none
        addTarget(self, action: #selector(changed), for: .editingChanged)
        reset()
    }
    required init?(coder: NSCoder) { fatalError() }

    private var hardwareKeyboard: Bool { GCKeyboard.coalesced != nil }

    func reset() {
        state = .ready
        text = ""
        backgroundColor = .clear
        textColor = .clear
        tintColor = .clear
        layer.borderWidth = 0
        // Taps on the cursor cell belong to the grid until editing starts.
        isUserInteractionEnabled = false
        // Without a hardware keyboard, selecting cells must not raise the keyboard.
        let wanted: UIView? = hardwareKeyboard ? nil : emptyInput
        if inputView !== wanted { inputView = wanted; if isFirstResponder { reloadInputViews() } }
    }

    func begin(_ initial: String, typed: Bool) {
        state = typed ? .typing : .editing
        text = initial
        showEditing()
        if inputView != nil { inputView = nil; reloadInputViews() }
        if !isFirstResponder { becomeFirstResponder() }
        if let end = endOfDocumentPosition as UITextPosition? { selectedTextRange = textRange(from: end, to: end) }
    }

    private func showEditing() {
        isUserInteractionEnabled = true
        backgroundColor = .white
        textColor = .black
        tintColor = .systemBlue
        layer.borderColor = UIColor.systemBlue.cgColor
        layer.borderWidth = 2
    }

    @objc private func changed() {
        if state == .ready, (text?.isEmpty == false || markedTextRange != nil) {
            state = .typing
            showEditing()
        }
        grid?.positionEditor()
        grid?.delegate?.gridSelectionChanged()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let key = presses.first?.key, let grid else { super.pressesBegan(presses, with: event); return }
        if markedTextRange != nil { super.pressesBegan(presses, with: event); return }
        switch state {
        case .ready:
            if grid.handleKey(key) { return }
        case .typing:
            // Arrow keys commit and move when editing began by typing (Excel's Enter mode).
            switch key.keyCode {
            case .keyboardUpArrow, .keyboardDownArrow, .keyboardLeftArrow, .keyboardRightArrow, .keyboardTab:
                grid.commitEdit()
                _ = grid.handleKey(key)
                return
            case .keyboardEscape: grid.cancelEdit(); return
            default: break
            }
        case .editing:
            switch key.keyCode {
            case .keyboardTab: grid.commitEdit(); _ = grid.handleKey(key); return
            case .keyboardEscape: grid.cancelEdit(); return
            default: break
            }
        }
        super.pressesBegan(presses, with: event)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        guard let grid else { return true }
        if state == .ready { grid.move(rows: 1, cols: 0, extend: false); return false }
        grid.commitEdit()
        grid.move(rows: 1, cols: 0, extend: false)
        return false
    }

    // In the ready state clipboard commands act on the selected cells.
    override func copy(_ sender: Any?) { if state == .ready { grid?.delegate?.gridCopy(cut: false) } else { super.copy(sender) } }
    override func cut(_ sender: Any?) { if state == .ready { grid?.delegate?.gridCopy(cut: true) } else { super.cut(sender) } }
    override func paste(_ sender: Any?) { if state == .ready { grid?.delegate?.gridPaste() } else { super.paste(sender) } }
    override func selectAll(_ sender: Any?) {
        if state == .ready, let grid {
            let end = CellRef(row: max(0, grid.sheet.usedRange?.end.row ?? 0), col: max(0, grid.sheet.usedRange?.end.col ?? 0))
            grid.selectRange(CellRange(CellRef(row: 0, col: 0), end))
        } else { super.selectAll(sender) }
    }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if state == .ready, [#selector(copy(_:)), #selector(cut(_:)), #selector(paste(_:)), #selector(selectAll(_:))].contains(action) { return true }
        return super.canPerformAction(action, withSender: sender)
    }
}
