import UIKit
import UniformTypeIdentifiers

/// Start screen laid out like the macOS start window: a sidebar with the HanX
/// mark and 새로 만들기 / 열기…, three "new" tiles, a 파일 열기 box that opens
/// the Files browser, and the recent documents list.
final class StartViewController: UIViewController {
    private let recentList = UIStackView()
    private let clearButton = UIButton(type: .system)
    private let sidebar = UIView()
    private var sidebarWidth: NSLayoutConstraint!

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = HanXTheme.paper
        buildSidebar()
        buildMain()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        rebuildRecent()
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        updateSidebarForWidth()
    }

    private func updateSidebarForWidth() {
        let compact = traitCollection.horizontalSizeClass == .compact
        sidebar.isHidden = compact
        sidebarWidth?.constant = compact ? 0 : 236
    }

    // MARK: Layout

    private func buildSidebar() {
        sidebar.backgroundColor = HanXTheme.toolbar
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sidebar)
        let mark = HanXMarkView()
        mark.translatesAutoresizingMaskIntoConstraints = false
        let name = UILabel()
        name.text = "HanX"
        name.font = .systemFont(ofSize: 30, weight: .semibold)
        name.textColor = HanXTheme.ink
        let newButton = SidebarRow(title: "새로 만들기", symbol: "plus.square.fill", selected: true) {}
        let openButton = SidebarRow(title: "열기…", symbol: "folder", selected: false) { [weak self] in self?.openBrowser() }
        let stack = UIStackView(arrangedSubviews: [mark, name, newButton, openButton])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 4
        stack.setCustomSpacing(12, after: mark)
        stack.setCustomSpacing(34, after: name)
        stack.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(stack)
        let about = UIButton(type: .system)
        about.setTitle("글꼴 추가…", for: .normal)
        about.titleLabel?.font = .systemFont(ofSize: 13)
        about.addAction(UIAction { [weak self] _ in self?.importFonts() }, for: .primaryActionTriggered)
        about.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(about)
        sidebarWidth = sidebar.widthAnchor.constraint(equalToConstant: 236)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: view.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sidebarWidth,
            mark.widthAnchor.constraint(equalToConstant: 60), mark.heightAnchor.constraint(equalToConstant: 60),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 40),
            stack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -14),
            about.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 24),
            about.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
        ])
        name.layoutMargins = .zero
        mark.transform = CGAffineTransform(translationX: 10, y: 0)
        name.transform = CGAffineTransform(translationX: 10, y: 0)
        updateSidebarForWidth()
    }

    private func buildMain() {
        let phone = UIDevice.current.userInterfaceIdiom == .phone
        let title = UILabel()
        title.text = "새로 만들기"
        title.font = .systemFont(ofSize: 27, weight: .semibold)
        title.textColor = HanXTheme.ink

        let tiles = UIStackView(arrangedSubviews: [
            TemplateTile(kind: .document, title: "새 문서", caption: "HWP, HWPX, DOCX") { [weak self] in self?.create(.blankDocument, ext: "hwpx", name: "새 문서") },
            TemplateTile(kind: .presentation, title: "새 프레젠테이션", caption: "PPTX") { [weak self] in self?.create(.presentation, ext: "pptx", name: "새 프레젠테이션") },
            TemplateTile(kind: .spreadsheet, title: "새 도표", caption: "XLSX, CSV") { [weak self] in self?.create(.spreadsheet, ext: "xlsx", name: "새 도표") },
        ])
        tiles.axis = .horizontal
        tiles.spacing = phone ? 12 : 24
        tiles.distribution = .fillEqually

        let openBox = OpenFileBox { [weak self] in self?.openBrowser() }

        let recentTitle = UILabel()
        recentTitle.text = "최근 문서"
        recentTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        recentTitle.textColor = HanXTheme.ink
        clearButton.setTitle("모두 지우기", for: .normal)
        clearButton.titleLabel?.font = .systemFont(ofSize: 12)
        clearButton.tintColor = HanXTheme.secondary
        clearButton.addAction(UIAction { [weak self] _ in RecentDocuments.clear(); self?.rebuildRecent() }, for: .primaryActionTriggered)
        let heading = UIStackView(arrangedSubviews: [recentTitle, UIView(), clearButton])
        heading.alignment = .center

        recentList.axis = .vertical
        recentList.spacing = 2

        let main = UIStackView(arrangedSubviews: [title, tiles, openBox, heading, recentList])
        main.axis = .vertical
        main.spacing = 8
        main.setCustomSpacing(28, after: title)
        main.setCustomSpacing(30, after: tiles)
        main.setCustomSpacing(30, after: openBox)
        main.setCustomSpacing(10, after: heading)
        main.translatesAutoresizingMaskIntoConstraints = false

        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        scroll.addSubview(main)
        let width = main.widthAnchor.constraint(equalToConstant: 660)
        width.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            main.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 56),
            main.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -40),
            main.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: phone ? 20 : 44),
            main.trailingAnchor.constraint(lessThanOrEqualTo: scroll.frameLayoutGuide.trailingAnchor, constant: phone ? -20 : -40),
            width,
        ])
    }

    private func rebuildRecent() {
        recentList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let urls = Array(RecentDocuments.urls.prefix(8))
        clearButton.isHidden = urls.isEmpty
        if urls.isEmpty {
            let empty = UILabel()
            empty.text = "최근 문서 없음"
            empty.font = .systemFont(ofSize: 14)
            empty.textColor = .tertiaryLabel
            recentList.addArrangedSubview(empty)
            return
        }
        for url in urls {
            recentList.addArrangedSubview(RecentRow(url: url, open: { [weak self] in self?.openFile(url) }, remove: { [weak self] in
                RecentDocuments.remove(url)
                self?.rebuildRecent()
            }))
        }
    }

    // MARK: Actions

    private func create(_ template: CreationRequest.Template, ext: String, name: String) {
        let request = CreationRequest(template: template, ext: ext, name: name)
        openGeneratedDocument(data: request.makeData(), name: name, ext: ext)
    }

    func openFile(_ url: URL) {
        dismissBrowserIfNeeded { EditorFactory.open(url, from: self) }
    }

    private func dismissBrowserIfNeeded(_ then: @escaping () -> Void) {
        if let browser = presentedViewController as? DocumentBrowserViewController {
            browser.dismiss(animated: true, completion: then)
        } else if presentedViewController == nil {
            then()
        } else {
            then()
        }
    }

    /// 파일 열기 / 열기…: the system Files browser (create, browse, recents, tags).
    func openBrowser() {
        let browser = DocumentBrowserViewController()
        browser.onOpen = { [weak self] url in self?.openFile(url) }
        browser.modalPresentationStyle = .fullScreen
        present(browser, animated: true)
    }

    private var fontDelegate: FontImportDelegate?

    private func importFonts() {
        let types = ["ttf", "otf", "ttc"].compactMap { UTType(filenameExtension: $0) }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = true
        let delegate = FontImportDelegate { [weak self] urls in
            let added = FontResolver.shared.importFonts(urls)
            self?.presentMessage(added.isEmpty ? "글꼴을 추가하지 못했습니다" : "글꼴을 추가했습니다",
                                 added.isEmpty ? "TrueType 또는 OpenType 글꼴 파일을 선택하세요." : added.joined(separator: ", "))
        }
        fontDelegate = delegate
        picker.delegate = delegate
        present(picker, animated: true)
    }
}

// MARK: - Start screen pieces

/// The HanX mark (folded sheet and two ribbons), drawn like Tools/make-icon.swift.
final class HanXMarkView: UIView {
    override init(frame: CGRect) { super.init(frame: frame); backgroundColor = .clear; contentMode = .redraw }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        // Square mark at the leading edge, whatever width the stack gives the view.
        let side = min(bounds.width, bounds.height)
        let k = side / 1024
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * k, y: (1024 - y) * k) }
        func polygon(_ pts: [(CGFloat, CGFloat)], _ color: UIColor) {
            let path = UIBezierPath()
            path.move(to: p(pts[0].0, pts[0].1))
            for q in pts.dropFirst() { path.addLine(to: p(q.0, q.1)) }
            path.close()
            color.setFill()
            path.fill()
        }
        func rgb(_ v: UInt32) -> UIColor { UIColor(red: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1) }
        let base = UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: side, height: side).insetBy(dx: 96 * k, dy: 96 * k), cornerRadius: 184 * k)
        if let g = UIGraphicsGetCurrentContext(), let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [rgb(0x2F6B9A).cgColor, rgb(0x234D76).cgColor] as CFArray, locations: [0, 1]) {
            g.saveGState(); base.addClip()
            g.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: side), options: [])
            g.restoreGState()
        }
        polygon([(256, 224), (256, 800), (288, 832), (640, 832), (768, 704), (768, 224), (736, 192), (288, 192)], .white)
        polygon([(640, 832), (640, 736), (672, 704), (768, 704)], rgb(0xDDEAF2))
        polygon([(328, 672), (442, 672), (696, 320), (582, 320)], rgb(0x234D76))
        polygon([(582, 672), (696, 672), (442, 320), (328, 320)], rgb(0x168A98))
    }
}

/// Sidebar navigation row (selected = selection fill + accent).
final class SidebarRow: UIControl {
    private let action: () -> Void
    private let selectedRow: Bool
    override var isHighlighted: Bool { didSet { updateLook() } }

    init(title: String, symbol: String, selected: Bool, action: @escaping () -> Void) {
        self.action = action
        selectedRow = selected
        super.init(frame: .zero)
        layer.cornerRadius = 6
        let icon = UIImageView(image: UIImage(systemName: symbol))
        icon.tintColor = selected ? HanXTheme.accent : HanXTheme.secondary
        icon.contentMode = .scaleAspectFit
        let label = UILabel()
        label.text = title
        label.font = .systemFont(ofSize: 14, weight: selected ? .semibold : .regular)
        label.textColor = selected ? HanXTheme.accent : HanXTheme.ink
        let stack = UIStackView(arrangedSubviews: [icon, label])
        stack.spacing = 10
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 40),
            icon.widthAnchor.constraint(equalToConstant: 20),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        accessibilityLabel = title
        accessibilityTraits = selected ? [.button, .selected] : .button
        isAccessibilityElement = true
        addAction(UIAction { [weak self] _ in self?.action() }, for: .touchUpInside)
        addInteraction(UIPointerInteraction(delegate: nil))
        updateLook()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func updateLook() {
        backgroundColor = selectedRow ? HanXTheme.selection : (isHighlighted ? HanXTheme.border : .clear)
    }
}

/// "새 문서" / "새 프레젠테이션" / "새 도표" tile: page preview card, title, caption.
final class TemplateTile: UIControl {
    private let action: () -> Void
    private let card = UIView()
    override var isHighlighted: Bool { didSet { card.layer.borderColor = (isHighlighted ? HanXTheme.accent : HanXTheme.border).cgColor } }

    init(kind: EditorKind, title: String, caption: String, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        card.backgroundColor = HanXTheme.canvas
        card.layer.cornerRadius = 8
        card.layer.borderWidth = 1
        card.layer.borderColor = HanXTheme.border.cgColor
        let preview = TemplatePreviewView(kind: kind)
        preview.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(preview)
        let t = UILabel()
        t.text = title
        t.font = .systemFont(ofSize: 14, weight: .semibold)
        t.textColor = HanXTheme.ink
        let c = UILabel()
        c.text = caption
        c.font = .systemFont(ofSize: 12)
        c.textColor = HanXTheme.secondary
        let stack = UIStackView(arrangedSubviews: [card, t, c])
        stack.axis = .vertical
        stack.spacing = 4
        stack.setCustomSpacing(10, after: card)
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.heightAnchor.constraint(equalToConstant: 150),
            preview.topAnchor.constraint(equalTo: card.topAnchor, constant: 14), preview.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
            preview.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14), preview.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
        ])
        isAccessibilityElement = true
        accessibilityLabel = title
        accessibilityTraits = .button
        addAction(UIAction { [weak self] _ in self?.action() }, for: .touchUpInside)
        addInteraction(UIPointerInteraction(delegate: nil))
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// Box-style "파일 열기" button above the recent documents.
final class OpenFileBox: UIControl {
    private let action: () -> Void
    override var isHighlighted: Bool { didSet { backgroundColor = isHighlighted ? HanXTheme.selection : HanXTheme.canvas } }

    init(action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        backgroundColor = HanXTheme.canvas
        layer.cornerRadius = 10
        layer.borderWidth = 1
        layer.borderColor = HanXTheme.border.cgColor
        let icon = UIImageView(image: UIImage(systemName: "folder", withConfiguration: UIImage.SymbolConfiguration(pointSize: 26, weight: .regular)))
        icon.tintColor = HanXTheme.accent
        let title = UILabel()
        title.text = "파일 열기"
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.textColor = HanXTheme.ink
        let caption = UILabel()
        caption.text = "파일 앱의 iPad, iCloud Drive 등에서 문서를 찾아 엽니다"
        caption.font = .systemFont(ofSize: 12)
        caption.textColor = HanXTheme.secondary
        let text = UIStackView(arrangedSubviews: [title, caption])
        text.axis = .vertical
        text.spacing = 2
        let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
        chevron.tintColor = HanXTheme.secondary
        let stack = UIStackView(arrangedSubviews: [icon, text, UIView(), chevron])
        stack.spacing = 14
        stack.alignment = .center
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 72),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        isAccessibilityElement = true
        accessibilityLabel = "파일 열기"
        accessibilityTraits = .button
        addAction(UIAction { [weak self] _ in self?.action() }, for: .touchUpInside)
        addInteraction(UIPointerInteraction(delegate: nil))
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// Recent document row: kind icon, name, "EXT ,  folder ,  date", remove button.
final class RecentRow: UIControl {
    private let openAction: () -> Void
    override var isHighlighted: Bool { didSet { backgroundColor = isHighlighted ? HanXTheme.selection : .clear } }

    init(url: URL, open: @escaping () -> Void, remove: @escaping () -> Void) {
        openAction = open
        super.init(frame: .zero)
        layer.cornerRadius = 6
        let ext = url.pathExtension.lowercased()
        let symbol: String
        switch ext {
        case "xlsx", "csv", "tsv": symbol = "tablecells"
        case "pptx": symbol = "rectangle.on.rectangle"
        case "pdf": symbol = "doc.richtext"
        default: symbol = "doc.text"
        }
        let icon = UIImageView(image: UIImage(systemName: symbol))
        icon.tintColor = HanXTheme.accent
        icon.contentMode = .scaleAspectFit
        let name = UILabel()
        name.text = url.deletingPathExtension().lastPathComponent
        name.font = .systemFont(ofSize: 14)
        name.textColor = HanXTheme.ink
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map {
            DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short)
        } ?? ""
        let detail = UILabel()
        detail.text = [ext.uppercased(), url.deletingLastPathComponent().lastPathComponent, date].filter { !$0.isEmpty }.joined(separator: " ,  ")
        detail.font = .systemFont(ofSize: 11.5)
        detail.textColor = HanXTheme.secondary
        let text = UIStackView(arrangedSubviews: [name, detail])
        text.axis = .vertical
        text.spacing = 1
        text.isUserInteractionEnabled = false
        let close = UIButton(type: .system)
        close.setImage(UIImage(systemName: "xmark"), for: .normal)
        close.tintColor = HanXTheme.secondary
        close.accessibilityLabel = "최근 문서에서 \(url.lastPathComponent) 제거"
        close.addAction(UIAction { _ in remove() }, for: .primaryActionTriggered)
        let spacer = UIView()
        spacer.isUserInteractionEnabled = false
        let stack = UIStackView(arrangedSubviews: [icon, text, spacer, close])
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        icon.isUserInteractionEnabled = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 52),
            icon.widthAnchor.constraint(equalToConstant: 24),
            close.widthAnchor.constraint(equalToConstant: 40), close.heightAnchor.constraint(equalToConstant: 40),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        accessibilityLabel = url.lastPathComponent
        addAction(UIAction { [weak self] _ in self?.openAction() }, for: .touchUpInside)
        addInteraction(UIPointerInteraction(delegate: nil))
    }
    required init?(coder: NSCoder) { fatalError() }
}
