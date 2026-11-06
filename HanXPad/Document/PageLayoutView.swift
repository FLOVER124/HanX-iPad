import UIKit

/// Print-layout editing: one UITextView per page, all sharing one layout
/// manager, so text flows from page to page while typing (Word's 인쇄 모양,
/// HWP's 쪽 윤곽). Pages are added and removed as layout completes.
final class PageLayoutView: UIView, NSLayoutManagerDelegate {
    let storage: NSTextStorage
    let layoutManager = HanXLayoutManager()
    private(set) var textViews: [PageTextView] = []
    private(set) var sheets: [PageSheetView] = []
    var page: PageSetup { didSet { relayoutPages() } }
    var decorations = PageDecorations() { didSet { sheets.forEach { $0.decorations = decorations } } }
    weak var textDelegate: UITextViewDelegate? { didSet { textViews.forEach { $0.delegate = textDelegate } } }
    /// Configures each new page's text view (gestures, actions).
    var configureTextView: ((PageTextView) -> Void)?
    var onPagesChanged: (() -> Void)?
    private var paginationScheduled = false

    static let gap: CGFloat = 24

    init(storage: NSTextStorage, page: PageSetup) {
        self.storage = storage
        self.page = page
        super.init(frame: .zero)
        backgroundColor = .clear
        layoutManager.allowsNonContiguousLayout = false
        layoutManager.usesFontLeading = true
        layoutManager.delegate = self
        storage.addLayoutManager(layoutManager)
        addPage()
        frame = CGRect(origin: .zero, size: contentSize)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { storage.removeLayoutManager(layoutManager) }

    var pageCount: Int { textViews.count }

    var contentSize: CGSize {
        CGSize(width: CGFloat(page.width) + PageLayoutView.gap * 2,
               height: PageLayoutView.gap + CGFloat(max(1, pageCount)) * (CGFloat(page.height) + PageLayoutView.gap))
    }

    func pageRect(_ i: Int) -> CGRect {
        let g = PageLayoutView.gap
        return CGRect(x: g, y: g + CGFloat(i) * (CGFloat(page.height) + g), width: CGFloat(page.width), height: CGFloat(page.height))
    }

    private var contentRect: CGRect {
        CGRect(x: CGFloat(page.marginLeft), y: CGFloat(page.marginTop), width: CGFloat(page.contentWidth), height: CGFloat(page.contentHeight))
    }

    private func addPage() {
        let index = textViews.count
        let sheet = PageSheetView(frame: pageRect(index))
        sheet.pageNumber = index + 1
        sheet.page = page
        sheet.decorations = decorations
        let rect = contentRect
        let container = NSTextContainer(size: rect.size)
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        layoutManager.addTextContainer(container)
        let tv = PageTextView(frame: rect, textContainer: container)
        tv.isScrollEnabled = false
        tv.textContainerInset = .zero
        tv.backgroundColor = .clear
        tv.allowsEditingTextAttributes = true
        tv.smartQuotesType = .no
        tv.smartDashesType = .no
        tv.smartInsertDeleteType = .no
        tv.autocorrectionType = .default
        tv.dataDetectorTypes = []
        tv.delegate = textDelegate
        tv.pageIndex = index
        container.size = rect.size
        sheet.addSubview(tv)
        addSubview(sheet)
        textViews.append(tv)
        sheets.append(sheet)
        configureTextView?(tv)
    }

    private func removeLastPage() {
        guard textViews.count > 1 else { return }
        let tv = textViews.removeLast()
        let sheet = sheets.removeLast()
        let wasFirstResponder = tv.isFirstResponder
        layoutManager.removeTextContainer(at: layoutManager.textContainers.count - 1)
        sheet.removeFromSuperview()
        if wasFirstResponder, let last = textViews.last {
            last.becomeFirstResponder()
            last.selectedRange = NSRange(location: storage.length, length: 0)
        }
    }

    private func relayoutPages() {
        let rect = contentRect
        for (i, tv) in textViews.enumerated() {
            sheets[i].frame = pageRect(i)
            sheets[i].page = page
            tv.frame = rect
            tv.textContainer.size = rect.size
        }
        paginate()
    }

    // MARK: Pagination

    func layoutManager(_ layoutManager: NSLayoutManager, didCompleteLayoutFor textContainer: NSTextContainer?, atEnd layoutFinishedFlag: Bool) {
        let containers = layoutManager.textContainers
        let needsMore = textContainer == nil || (textContainer === containers.last && !layoutFinishedFlag)
        let mayShrink = layoutFinishedFlag && textContainer !== containers.last
        if (needsMore || mayShrink) && !paginationScheduled {
            paginationScheduled = true
            DispatchQueue.main.async { [weak self] in self?.paginate() }
        }
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
                       forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        PageBreaks.action(layoutManager, action, charIndex)
    }

    func paginate() {
        paginationScheduled = false
        var guardCount = 0
        while guardCount < 10_000, let last = layoutManager.textContainers.last {
            guardCount += 1
            let range = layoutManager.glyphRange(for: last)
            if NSMaxRange(range) < layoutManager.numberOfGlyphs { addPage() } else { break }
        }
        while textViews.count > 1, let last = layoutManager.textContainers.last {
            let range = layoutManager.glyphRange(for: last)
            if range.length == 0 { removeLastPage() } else { break }
        }
        for (i, sheet) in sheets.enumerated() {
            sheet.pageNumber = i + 1
            sheet.pageCount = sheets.count
            textViews[i].pageIndex = i
        }
        let size = contentSize
        if bounds.size != size { bounds.size = size }
        onPagesChanged?()
    }

    /// Text view showing a character index (for moving the caret across pages).
    func textView(forCharacterAt index: Int) -> PageTextView? {
        guard storage.length > 0 else { return textViews.first }
        let glyphs = layoutManager.numberOfGlyphs
        guard glyphs > 0 else { return textViews.first }
        let ch = max(0, min(index, storage.length - 1))
        let glyph = min(layoutManager.glyphIndexForCharacter(at: ch), glyphs - 1)
        guard let container = layoutManager.textContainer(forGlyphAt: glyph, effectiveRange: nil) else { return textViews.last }
        if index >= storage.length, let last = textViews.last(where: { layoutManager.glyphRange(for: $0.textContainer).length > 0 }) { return last }
        return textViews.first { $0.textContainer === container }
    }

    /// Re-rasterises text at the zoom scale so it stays sharp.
    func applyRenderingScale(_ scale: CGFloat) {
        func walk(_ v: UIView) {
            v.contentScaleFactor = scale
            v.layer.contentsScale = scale
            v.setNeedsDisplay()
            v.subviews.forEach(walk)
        }
        sheets.forEach(walk)
    }
}

enum PageBreaks {
    /// U+000C ends the page: TextKit moves the following text to the next container.
    static func action(_ lm: NSLayoutManager, _ action: NSLayoutManager.ControlCharacterAction, _ charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        guard let storage = lm.textStorage, charIndex < storage.length else { return action }
        if (storage.string as NSString).character(at: charIndex) == 0x0C { return .containerBreak }
        return action
    }
}

/// Draws paragraph bottom borders (구분선), which UIKit's TextKit has no attribute for.
final class HanXLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, glyphsToShow.length > 0, let ctx = UIGraphicsGetCurrentContext(),
              let container = textContainer(forGlyphAt: glyphsToShow.location, effectiveRange: nil) else { return }
        let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let ns = storage.string as NSString
        storage.enumerateAttribute(.hwBottomBorder, in: chars, options: []) { value, range, _ in
            guard let data = value as? Data, let border = try? JSONDecoder().decode(BorderLine.self, from: data), border.visible else { return }
            var loc = range.location
            while loc < NSMaxRange(range) {
                let para = ns.paragraphRange(for: NSRange(location: loc, length: 0))
                let last = max(para.location, NSMaxRange(para) - 1)
                let glyph = glyphIndexForCharacter(at: last)
                if glyph < numberOfGlyphs, NSLocationInRange(glyph, glyphsToShow),
                   textContainer(forGlyphAt: glyph, effectiveRange: nil) === container {
                    let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                    let ps = storage.attribute(.paragraphStyle, at: last, effectiveRange: nil) as? NSParagraphStyle
                    let left = origin.x + (ps?.headIndent ?? 0)
                    let right = origin.x + container.size.width + min(0, ps?.tailIndent ?? 0)
                    let y = origin.y + line.maxY - CGFloat(border.width) / 2
                    ctx.saveGState()
                    ctx.setStrokeColor(border.color.cgColor)
                    ctx.setLineWidth(CGFloat(max(0.5, border.width)))
                    if border.style == .dotted { ctx.setLineDash(phase: 0, lengths: [1, 2]) }
                    if border.style == .dashed { ctx.setLineDash(phase: 0, lengths: [4, 2]) }
                    ctx.move(to: CGPoint(x: left, y: y)); ctx.addLine(to: CGPoint(x: right, y: y)); ctx.strokePath()
                    ctx.restoreGState()
                }
                loc = NSMaxRange(para)
            }
        }
    }
}

/// Header / footer (머리말 / 꼬리말) drawn on every page.
struct PageDecorations {
    var header: NSAttributedString?
    var footer: NSAttributedString?
    /// HWP measures header/footer boxes inside the margins; Word from the paper edge.
    var hancomGeometry = true

    static func make(header: [Block]?, footer: [Block]?, page: PageSetup, images: [String: ImageData], source: SourceFormat) -> PageDecorations {
        let ctx = TextBridge.Context(images: images, source: source)
        func text(_ b: [Block]?) -> NSAttributedString? {
            guard let b, !b.isEmpty else { return nil }
            let s = TextBridge.build(b, width: page.contentWidth, ctx: ctx)
            var hasField = false
            s.enumerateAttribute(.hwField, in: NSRange(location: 0, length: s.length)) { v, _, _ in if v != nil { hasField = true } }
            return s.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !hasField ? nil : s
        }
        return PageDecorations(header: text(header), footer: text(footer), hancomGeometry: source != .docx)
    }

    func draw(page: PageSetup, pageNumber: Int, pageCount: Int, in bounds: CGRect) {
        let x = CGFloat(page.marginLeft), w = CGFloat(page.contentWidth)
        let opts: NSStringDrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        if let h = header {
            let text = TextBridge.resolveFields(h, page: pageNumber, pages: pageCount)
            let top = hancomGeometry ? CGFloat(page.marginTop - page.header) : CGFloat(page.header)
            let y = max(4, top)
            text.draw(with: CGRect(x: x, y: y, width: w, height: max(10, CGFloat(page.marginTop) - y)), options: opts, context: nil)
        }
        if let f = footer {
            let text = TextBridge.resolveFields(f, page: pageNumber, pages: pageCount)
            let height = ceil(text.boundingRect(with: CGSize(width: w, height: 1000), options: opts, context: nil).height)
            let top = hancomGeometry ? bounds.height - CGFloat(page.marginBottom) + 2 : bounds.height - CGFloat(page.footer) - height
            text.draw(with: CGRect(x: x, y: top, width: w, height: height + 2), options: opts, context: nil)
        }
    }
}

final class PageSheetView: UIView {
    var pageNumber = 1 { didSet { if oldValue != pageNumber { setNeedsDisplay() } } }
    var pageCount = 1 { didSet { if oldValue != pageCount { setNeedsDisplay() } } }
    var page = PageSetup() { didSet { setNeedsDisplay() } }
    var decorations = PageDecorations() { didSet { setNeedsDisplay() } }
    var showsMarginGuides = true { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .white
        contentMode = .redraw
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: 2)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        UIColor.white.setFill()
        UIRectFill(bounds)
        if showsMarginGuides, let g = UIGraphicsGetCurrentContext() {
            // Corner marks at the text area, as HWP's 쪽 윤곽 shows them.
            g.setStrokeColor(UIColor(white: 0.78, alpha: 1).cgColor)
            g.setLineWidth(0.5)
            let r = CGRect(x: page.marginLeft, y: page.marginTop, width: page.contentWidth, height: page.contentHeight)
            let k: CGFloat = 12
            for (p, dx, dy) in [(CGPoint(x: r.minX, y: r.minY), -k, -k), (CGPoint(x: r.maxX, y: r.minY), k, -k),
                                (CGPoint(x: r.minX, y: r.maxY), -k, k), (CGPoint(x: r.maxX, y: r.maxY), k, k)] {
                g.move(to: p); g.addLine(to: CGPoint(x: p.x + dx, y: p.y))
                g.move(to: p); g.addLine(to: CGPoint(x: p.x, y: p.y + dy))
            }
            g.strokePath()
        }
        decorations.draw(page: page, pageNumber: pageNumber, pageCount: pageCount, in: bounds)
    }
}

/// UITextView for one page. Formatting shortcuts route through the editor so
/// they update the HanX attributes (face names, synthetic bold) consistently.
final class PageTextView: UITextView {
    var pageIndex = 0
    weak var actions: PageTextActions?

    override func toggleBoldface(_ sender: Any?) { actions?.pageTextToggle("bold") }
    override func toggleItalics(_ sender: Any?) { actions?.pageTextToggle("italic") }
    override func toggleUnderline(_ sender: Any?) { actions?.pageTextToggle("underline") }

    override func paste(_ sender: Any?) {
        let board = UIPasteboard.general
        if !board.hasStrings, board.hasImages, let image = board.image {
            actions?.pageTextPasteImage(image)
            return
        }
        super.paste(sender)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) && UIPasteboard.general.hasImages { return isEditable }
        return super.canPerformAction(action, withSender: sender)
    }
}

protocol PageTextActions: AnyObject {
    func pageTextToggle(_ id: String)
    func pageTextPasteImage(_ image: UIImage)
}

/// Lays text out on pages without views and draws vector PDF pages.
enum PageExporter {
    private final class Delegate: NSObject, NSLayoutManagerDelegate {
        func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
                           forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
            PageBreaks.action(layoutManager, action, charIndex)
        }
    }

    static func pdf(storage source: NSTextStorage, page: PageSetup, decorations: PageDecorations) -> Data {
        let storage = NSTextStorage(attributedString: source)
        let lm = HanXLayoutManager()
        let delegate = Delegate()
        lm.delegate = delegate
        lm.allowsNonContiguousLayout = false
        lm.usesFontLeading = true
        storage.addLayoutManager(lm)
        let content = CGSize(width: page.contentWidth, height: page.contentHeight)
        func add() {
            let c = NSTextContainer(size: content)
            c.lineFragmentPadding = 0
            lm.addTextContainer(c)
        }
        add()
        var guardCount = 0
        while guardCount < 10_000, let last = lm.textContainers.last {
            guardCount += 1
            let r = lm.glyphRange(for: last)
            if NSMaxRange(r) < lm.numberOfGlyphs { add() } else { break }
        }
        while lm.textContainers.count > 1, let last = lm.textContainers.last, lm.glyphRange(for: last).length == 0 {
            lm.removeTextContainer(at: lm.textContainers.count - 1)
        }
        let bounds = CGRect(x: 0, y: 0, width: page.width, height: page.height)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        TableAttachment.exportMode = true
        defer { TableAttachment.exportMode = false; storage.removeLayoutManager(lm) }
        let count = lm.textContainers.count
        return renderer.pdfData { ctx in
            for (i, container) in lm.textContainers.enumerated() {
                ctx.beginPage()
                decorations.draw(page: page, pageNumber: i + 1, pageCount: count, in: bounds)
                let origin = CGPoint(x: page.marginLeft, y: page.marginTop)
                let glyphs = lm.glyphRange(for: container)
                guard glyphs.length > 0 else { continue }
                lm.drawBackground(forGlyphRange: glyphs, at: origin)
                lm.drawGlyphs(forGlyphRange: glyphs, at: origin)
                let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
                storage.enumerateAttribute(.attachment, in: chars, options: []) { value, range, _ in
                    guard let table = value as? TableAttachment else { return }
                    let g = lm.glyphIndexForCharacter(at: range.location)
                    let line = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
                    let loc = lm.location(forGlyphAt: g)
                    let top = CGPoint(x: origin.x + line.minX + loc.x, y: origin.y + line.minY + loc.y - table.bounds.height)
                    TableRenderer.draw(table.table, layout: table.layout, at: top, ctx: table.context)
                }
            }
        }
    }
}
