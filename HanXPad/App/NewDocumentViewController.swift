import UIKit

/// What the "새로 만들기" sheet produces. The file is written to a temporary
/// folder and moved by the document browser into the chosen location.
struct CreationRequest {
    enum Template { case blankDocument, letter, labels, presentation, spreadsheet }
    var template: Template
    var ext: String
    var name: String

    func makeData() -> Data {
        switch template {
        case .blankDocument, .letter, .labels:
            let source: SourceFormat = ext == "docx" ? .docx : ext == "hwp" ? .hwp : ext == "hwpx" ? .hwpx : .docx
            let doc: UDocument
            switch template {
            case .letter: doc = DocumentTemplates.make("letter") ?? UDocument()
            case .labels: doc = DocumentTemplates.make("labels") ?? UDocument()
            default:
                doc = UDocument()
                var p = Paragraph()
                p.markProps = TextDocument.defaultCharProps(for: source)
                p.props = TextDocument.defaultParaProps(for: source)
                doc.sections = [Section(page: source == .docx ? .letterWord : .a4Hwp, blocks: [.paragraph(p)])]
            }
            doc.source = source
            switch ext {
            case "hwpx": return HWPXWriter(doc).write()
            case "hwp": return HWP5Writer(doc).write()
            case "docx": return DOCXWriter(doc).write()
            default: return HanXFile.encode(.document, payload: DOCXWriter(doc).write())
            }
        case .presentation:
            let pres = Presentation.blank()
            let pptx = PPTXWriter.write(pres)
            return ext == "hanx" ? HanXFile.encode(.presentation, payload: pptx) : pptx
        case .spreadsheet:
            let book = Workbook()
            switch ext {
            case "csv": return Data()
            case "hanx": return HanXFile.encode(.spreadsheet, payload: XLSXWriter.write(book))
            default: return XLSXWriter.write(book)
            }
        }
    }

    func makeTemporaryFile() throws -> URL {
        try GeneratedFiles.temporary(makeData(), name: name, ext: ext)
    }
}

final class NewDocumentViewController: UIViewController, UIAdaptivePresentationControllerDelegate {
    var onCreate: ((CreationRequest) -> Void)?
    var onCancel: (() -> Void)?

    private let nameField = UITextField()
    private let documentFormat = UISegmentedControl(items: ["HWPX", "HWP", "DOCX", "HanX"])
    private let slideFormat = UISegmentedControl(items: ["PPTX", "HanX"])
    private let sheetFormat = UISegmentedControl(items: ["XLSX", "CSV", "HanX"])

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "새로 만들기"
        view.backgroundColor = HanXTheme.canvas
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true) { self?.onCancel?() }
        })
        documentFormat.selectedSegmentIndex = 0
        slideFormat.selectedSegmentIndex = 0
        sheetFormat.selectedSegmentIndex = 0

        nameField.placeholder = "제목 없음"
        nameField.borderStyle = .roundedRect
        nameField.clearButtonMode = .whileEditing
        nameField.returnKeyType = .done
        nameField.font = .systemFont(ofSize: 17)
        let nameLabel = label("이름", size: 13, color: HanXTheme.secondary)

        let tiles = UIStackView(arrangedSubviews: [
            tile(kind: .document, title: "새 문서", caption: "한글·Word 호환", format: documentFormat) { [weak self] in self?.create(.blankDocument, self?.documentExt ?? "hwpx") },
            tile(kind: .presentation, title: "새 프레젠테이션", caption: "PowerPoint 호환", format: slideFormat) { [weak self] in self?.create(.presentation, self?.slideFormat.selectedSegmentIndex == 1 ? "hanx" : "pptx") },
            tile(kind: .spreadsheet, title: "새 도표", caption: "Excel 호환", format: sheetFormat) { [weak self] in
                guard let self else { return }
                self.create(.spreadsheet, ["xlsx", "csv", "hanx"][max(0, self.sheetFormat.selectedSegmentIndex)])
            },
        ])
        tiles.axis = .horizontal
        tiles.spacing = 16
        tiles.distribution = .fillEqually

        let templateTitle = label("양식", size: 20, weight: .semibold)
        let letter = templateButton("편지지", symbol: "envelope") { [weak self] in self?.create(.letter, self?.documentExt ?? "hwpx") }
        let labels = templateButton("라벨 2열 × 7행", symbol: "square.grid.2x2") { [weak self] in self?.create(.labels, self?.documentExt ?? "hwpx") }
        let templates = UIStackView(arrangedSubviews: [letter, labels, UIView()])
        templates.spacing = 12

        let note = label("양식은 위 '새 문서'에서 고른 형식으로 만듭니다.", size: 13, color: HanXTheme.secondary)
        note.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [nameLabel, nameField, tiles, templateTitle, templates, note])
        stack.axis = .vertical
        stack.spacing = 12
        stack.setCustomSpacing(24, after: nameField)
        stack.setCustomSpacing(28, after: tiles)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.keyboardDismissMode = .interactive
        view.addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
        ])
        preferredContentSize = CGSize(width: 720, height: 560)
    }

    private var documentExt: String { ["hwpx", "hwp", "docx", "hanx"][max(0, documentFormat.selectedSegmentIndex)] }

    private func create(_ template: CreationRequest.Template, _ ext: String) {
        let typed = nameField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallback: String
        switch template {
        case .blankDocument: fallback = "새 문서"
        case .letter: fallback = "편지지"
        case .labels: fallback = "라벨"
        case .presentation: fallback = "새 프레젠테이션"
        case .spreadsheet: fallback = "새 도표"
        }
        onCreate?(CreationRequest(template: template, ext: ext, name: typed.isEmpty ? fallback : typed))
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { onCancel?() }

    private func label(_ text: String, size: CGFloat, weight: UIFont.Weight = .regular, color: UIColor = HanXTheme.ink) -> UILabel {
        let l = UILabel()
        l.text = text
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        return l
    }

    private func tile(kind: EditorKind, title: String, caption: String, format: UISegmentedControl, action: @escaping () -> Void) -> UIView {
        let preview = TemplatePreviewView(kind: kind)
        preview.heightAnchor.constraint(equalToConstant: 150).isActive = true
        let button = UIButton(type: .system)
        var config = UIButton.Configuration.filled()
        config.title = title
        config.subtitle = caption
        config.cornerStyle = .medium
        config.titleAlignment = .center
        button.configuration = config
        button.addAction(UIAction { _ in action() }, for: .primaryActionTriggered)
        let previewButton = UIButton(type: .custom)
        previewButton.addAction(UIAction { _ in action() }, for: .primaryActionTriggered)
        previewButton.accessibilityLabel = title
        preview.isUserInteractionEnabled = false
        previewButton.addSubview(preview)
        preview.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: previewButton.topAnchor), preview.bottomAnchor.constraint(equalTo: previewButton.bottomAnchor),
            preview.leadingAnchor.constraint(equalTo: previewButton.leadingAnchor), preview.trailingAnchor.constraint(equalTo: previewButton.trailingAnchor),
        ])
        let stack = UIStackView(arrangedSubviews: [previewButton, format, button])
        stack.axis = .vertical
        stack.spacing = 10
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.backgroundColor = HanXTheme.paper
        stack.layer.cornerRadius = 12
        stack.layer.borderColor = HanXTheme.border.cgColor
        stack.layer.borderWidth = 1
        return stack
    }

    private func templateButton(_ title: String, symbol: String, action: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.gray()
        config.title = title
        config.image = UIImage(systemName: symbol)
        config.imagePadding = 8
        config.cornerStyle = .medium
        config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
        let button = UIButton(configuration: config, primaryAction: UIAction { _ in action() })
        return button
    }
}

/// Miniature page previews for the template tiles (drawn, no bitmaps).
final class TemplatePreviewView: UIView {
    let kind: EditorKind
    init(kind: EditorKind) {
        self.kind = kind
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        let r = bounds.insetBy(dx: 8, dy: 6)
        let accent = HanXTheme.accent
        let line = HanXTheme.border
        switch kind {
        case .presentation:
            let slide = CGRect(x: r.minX, y: r.midY - r.width * 0.28, width: r.width, height: r.width * 0.56)
            UIColor.white.setFill(); UIBezierPath(roundedRect: slide, cornerRadius: 4).fill()
            line.setStroke(); UIBezierPath(roundedRect: slide, cornerRadius: 4).stroke()
            accent.setFill()
            UIBezierPath(roundedRect: CGRect(x: slide.minX + slide.width * 0.2, y: slide.minY + slide.height * 0.35, width: slide.width * 0.6, height: 8), cornerRadius: 4).fill()
            line.setFill()
            UIBezierPath(roundedRect: CGRect(x: slide.minX + slide.width * 0.3, y: slide.minY + slide.height * 0.55, width: slide.width * 0.4, height: 6), cornerRadius: 3).fill()
        case .spreadsheet:
            let sheet = CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height)
            UIColor.white.setFill(); UIBezierPath(roundedRect: sheet, cornerRadius: 4).fill()
            line.setStroke()
            let path = UIBezierPath()
            for i in 1..<6 { let y = sheet.minY + sheet.height * CGFloat(i) / 6; path.move(to: CGPoint(x: sheet.minX, y: y)); path.addLine(to: CGPoint(x: sheet.maxX, y: y)) }
            for i in 1..<4 { let x = sheet.minX + sheet.width * CGFloat(i) / 4; path.move(to: CGPoint(x: x, y: sheet.minY)); path.addLine(to: CGPoint(x: x, y: sheet.maxY)) }
            path.stroke()
            UIBezierPath(roundedRect: sheet, cornerRadius: 4).stroke()
            accent.withAlphaComponent(0.25).setFill()
            UIBezierPath(rect: CGRect(x: sheet.minX + 1, y: sheet.minY + 1, width: sheet.width - 2, height: sheet.height / 6 - 1)).fill()
        default:
            let w = min(r.width, r.height * 0.72)
            let page = CGRect(x: r.midX - w / 2, y: r.minY, width: w, height: r.height)
            UIColor.white.setFill(); UIBezierPath(roundedRect: page, cornerRadius: 4).fill()
            line.setStroke(); UIBezierPath(roundedRect: page, cornerRadius: 4).stroke()
            accent.setFill()
            UIBezierPath(roundedRect: CGRect(x: page.minX + 12, y: page.minY + 14, width: page.width * 0.5, height: 6), cornerRadius: 3).fill()
            line.setFill()
            for i in 0..<6 {
                UIBezierPath(roundedRect: CGRect(x: page.minX + 12, y: page.minY + 30 + CGFloat(i) * 14, width: page.width - 24 - CGFloat(i % 3) * 10, height: 4), cornerRadius: 2).fill()
            }
        }
    }
}
