import UIKit
import PDFKit
import PencilKit

/// Goodnotes-style handwriting on PDF pages: one PencilKit canvas over each
/// visible page (PDFView page overlays), the system tool picker (pen,
/// highlighter, eraser, lasso, ruler) and finger scrolling.
///
/// Strokes are written into the PDF as standard ink annotations (vector, visible
/// in any PDF app). The PencilKit drawing is also stored on the first annotation
/// so HanX can turn the ink back into editable strokes next time.
final class PDFInkController: NSObject, PDFPageOverlayViewProvider, PKCanvasViewDelegate {
    static let marker = "HanXInk"
    static let drawingKey = PDFAnnotationKey(rawValue: "/HanXInkDrawing")

    let toolPicker = PKToolPicker()
    private var canvases: [PDFPage: PKCanvasView] = [:]
    private(set) var drawings: [PDFPage: PKDrawing] = [:]
    private(set) var changed = false
    weak var pdfView: PDFView?
    var onChange: (() -> Void)?

    // MARK: Lifecycle

    /// Pulls HanX ink annotations off the pages into editable drawings.
    func begin(on view: PDFView, document: PDFDocument) {
        pdfView = view
        drawings = [:]
        canvases = [:]
        changed = false
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            let ours = page.annotations.filter { $0.contents == PDFInkController.marker }
            guard !ours.isEmpty else { continue }
            let encoded = ours.lazy.compactMap { $0.value(forAnnotationKey: PDFInkController.drawingKey) as? String }.first
            guard let encoded, let data = Data(base64Encoded: encoded), let drawing = try? PKDrawing(data: data) else { continue }
            ours.forEach { page.removeAnnotation($0) }
            drawings[page] = drawing
        }
        // The overlay provider must be in place before the document is shown.
        view.document = nil
        view.pageOverlayViewProvider = self
        view.isInMarkupMode = true
        view.document = document
        toolPicker.setVisible(true, forFirstResponder: view)
        view.becomeFirstResponder()
    }

    /// Writes the drawings back as ink annotations; returns true if anything changed.
    @discardableResult
    func end(document: PDFDocument) -> Bool {
        for (page, canvas) in canvases { drawings[page] = canvas.drawing; toolPicker.removeObserver(canvas) }
        if let view = pdfView {
            toolPicker.setVisible(false, forFirstResponder: view)
            for canvas in canvases.values { toolPicker.setVisible(false, forFirstResponder: canvas) }
            view.isInMarkupMode = false
            view.pageOverlayViewProvider = nil
        }
        canvases = [:]
        for (page, drawing) in drawings where !drawing.strokes.isEmpty && page.document === document {
            for a in PDFInkController.annotations(for: drawing, page: page) { page.addAnnotation(a) }
        }
        let result = changed
        drawings = [:]
        changed = false
        return result
    }

    // MARK: PDFPageOverlayViewProvider

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        let canvas = canvases[page] ?? PKCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .default
        canvas.isScrollEnabled = false
        canvas.delegate = self
        canvas.drawing = drawings[page] ?? PKDrawing()
        canvases[page] = canvas
        toolPicker.addObserver(canvas)
        toolPicker.setVisible(true, forFirstResponder: canvas)
        return canvas
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        guard let canvas = overlayView as? PKCanvasView else { return }
        drawings[page] = canvas.drawing
        toolPicker.removeObserver(canvas)
        canvases[page] = nil
    }

    // MARK: PKCanvasViewDelegate

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        if !canvasView.isFirstResponder { canvasView.becomeFirstResponder() }
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        for (page, canvas) in canvases where canvas === canvasView { drawings[page] = canvas.drawing }
        changed = true
        onChange?()
    }

    // MARK: Ink annotations

    /// One ink annotation per stroke (each keeps its own colour and width), in page space.
    static func annotations(for drawing: PKDrawing, page: PDFPage) -> [PDFAnnotation] {
        let box = page.bounds(for: .cropBox)
        var out: [PDFAnnotation] = []
        for stroke in drawing.strokes {
            let path = UIBezierPath()
            var widths: CGFloat = 0, count: CGFloat = 0
            for (i, point) in stroke.path.interpolatedPoints(by: .distance(1.5)).enumerated() {
                let p = point.location.applying(stroke.transform)
                // Overlay space is top-left origin; annotation space is y-up from the box origin.
                let q = CGPoint(x: p.x, y: box.height - p.y)
                if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
                widths += point.size.width
                count += 1
            }
            guard count > 0 else { continue }
            let annotation = PDFAnnotation(bounds: box, forType: .ink, withProperties: nil)
            annotation.add(path)
            let border = PDFBorder()
            border.lineWidth = max(0.5, widths / count)
            annotation.border = border
            var color = stroke.ink.color
            if stroke.ink.inkType == .marker { color = color.withAlphaComponent(0.35) }
            annotation.color = color
            annotation.contents = marker
            out.append(annotation)
        }
        out.first?.setValue(drawing.dataRepresentation().base64EncodedString(), forAnnotationKey: drawingKey)
        return out
    }
}
