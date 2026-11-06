import UIKit

/// Chrome shared by the four editors: navigation bar (close, undo/redo, save,
/// export/print), the ribbon, keyboard-aware content area and the
/// save-confirmation flow for converted formats.
class HanXEditorViewController: UIViewController, UIDocumentPickerDelegate {
    let baseDocument: HanXBaseDocument
    let contentView = UIView()
    private(set) var ribbon: RibbonView?
    private var undoItem: UIBarButtonItem!
    private var redoItem: UIBarButtonItem!
    private(set) var saveItem: UIBarButtonItem!
    private(set) var exportItem: UIBarButtonItem!
    private var observers: [NSObjectProtocol] = []
    private var closeAfterExport = false

    init(baseDocument: HanXBaseDocument) {
        self.baseDocument = baseDocument
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    override var undoManager: UndoManager? { baseDocument.undoManager }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = HanXTheme.canvas
        title = baseDocument.displayTitle
        navigationItem.style = .editor
        navigationItem.documentProperties = UIDocumentProperties(url: baseDocument.fileURL)
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = HanXTheme.toolbar
        appearance.shadowColor = .clear
        navigationItem.standardAppearance = appearance
        navigationItem.scrollEdgeAppearance = appearance
        navigationItem.compactAppearance = appearance

        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "닫기", image: UIImage(systemName: "xmark"), primaryAction: UIAction { [weak self] _ in
            self?.closeDocument(nil)
        })
        undoItem = UIBarButtonItem(title: "실행 취소", image: UIImage(systemName: "arrow.uturn.backward"), primaryAction: UIAction { [weak self] _ in self?.performUndo(redo: false) })
        redoItem = UIBarButtonItem(title: "다시 실행", image: UIImage(systemName: "arrow.uturn.forward"), primaryAction: UIAction { [weak self] _ in self?.performUndo(redo: true) })
        saveItem = UIBarButtonItem(title: "저장", image: UIImage(systemName: "square.and.arrow.down"), primaryAction: UIAction { [weak self] _ in self?.saveDocument(nil) })
        exportItem = UIBarButtonItem(title: "내보내기", image: UIImage(systemName: "square.and.arrow.up"), menu: exportMenu())
        navigationItem.rightBarButtonItems = [exportItem, saveItem, redoItem, undoItem] + extraBarItems()

        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.backgroundColor = HanXTheme.canvas
        contentView.clipsToBounds = true
        view.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
        contentTop = contentView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor)
        contentTop?.isActive = true

        let center = NotificationCenter.default
        for name in [Notification.Name.NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            observers.append(center.addObserver(forName: name, object: baseDocument.undoManager, queue: .main) { [weak self] _ in self?.updateChrome() })
        }
        observers.append(center.addObserver(forName: UIDocument.stateChangedNotification, object: baseDocument, queue: .main) { [weak self] _ in
            self?.documentStateChanged()
        })
        updateChrome()
    }

    private var contentTop: NSLayoutConstraint?

    /// Subclasses may add items (e.g. PDF mode switch) after the standard ones.
    func extraBarItems() -> [UIBarButtonItem] { [] }

    func installRibbon(_ tabs: [RibbonView.Tab]) {
        let r = RibbonView(tabs: tabs)
        r.host = self
        r.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(r)
        contentTop?.isActive = false
        NSLayoutConstraint.activate([
            r.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            r.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            r.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: r.bottomAnchor),
        ])
        ribbon = r
    }

    // MARK: Hooks

    /// Finish in-progress typing (cell editors, text overlays) before saving.
    func commitPendingEdits() {}
    func didFinishPresenting() { presentImportWarnings() }
    func willCloseDocument() {}

    func updateChrome() {
        undoItem?.isEnabled = baseDocument.undoManager?.canUndo ?? false
        redoItem?.isEnabled = baseDocument.undoManager?.canRedo ?? false
        title = baseDocument.displayTitle + (baseDocument.hasUnsavedChanges ? " •" : "")
        ribbon?.refresh()
    }

    func performUndo(redo: Bool) {
        commitPendingEdits()
        guard let um = baseDocument.undoManager else { return }
        if redo { if um.canRedo { um.redo() } } else if um.canUndo { um.undo() }
        updateChrome()
    }

    private func presentImportWarnings() {
        let notices = baseDocument.importWarnings.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !notices.isEmpty else { return }
        baseDocument.importWarnings = []
        let text = notices.count > 6 ? notices.prefix(6).joined(separator: "\n\n") + "\n\n외 \(notices.count - 6)개" : notices.joined(separator: "\n\n")
        presentMessage("문서 가져오기 안내", text)
    }

    private func documentStateChanged() {
        let state = baseDocument.documentState
        if state.contains(.inConflict) {
            // Keep what is on screen; older versions stay in the file's version history.
            if let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: baseDocument.fileURL) {
                for v in versions { v.isResolved = true }
            }
            try? NSFileVersion.removeOtherVersionsOfItem(at: baseDocument.fileURL)
        }
        if state.contains(.savingError) {
            presentMessage("저장하지 못했습니다", "파일 위치에 쓸 수 있는지 확인하고 다시 저장하세요.")
        }
        updateChrome()
    }

    // MARK: Save

    @objc func saveDocument(_ sender: Any?) {
        commitPendingEdits()
        let doc = baseDocument
        if doc.inPlaceSaveConfirmed && doc.canWriteOriginalFormat { performSave(); return }
        let ext = doc.fileExtension.uppercased()
        let sheet = UIAlertController(title: "\(ext) 파일 저장",
                                      message: doc.canWriteOriginalFormat
                                        ? "원본 파일을 HanX가 다시 써서 저장합니다. 변환 과정에서 일부 서식이 달라질 수 있습니다. 원본을 유지하려면 사본으로 저장하세요."
                                        : "이 형식은 원본에 다시 쓰지 않습니다. 사본으로 저장하세요.",
                                      preferredStyle: .actionSheet)
        if doc.canWriteOriginalFormat {
            sheet.addAction(UIAlertAction(title: "원본(\(ext))에 저장", style: .default) { [weak self] _ in
                doc.inPlaceSaveConfirmed = true
                self?.performSave()
            })
        }
        sheet.addAction(UIAlertAction(title: "HanX 파일로 사본 저장…", style: .default) { [weak self] _ in
            guard let self else { return }
            let hanx = doc.exportFormats.first { $0.ext == "hanx" } ?? doc.exportFormats.first
            if let hanx { self.export(hanx) }
        })
        sheet.addAction(UIAlertAction(title: "다른 형식으로 내보내기…", style: .default) { [weak self] _ in self?.exportDocument(nil) })
        sheet.addAction(UIAlertAction(title: "취소", style: .cancel))
        sheet.popoverPresentationController?.barButtonItem = saveItem
        present(sheet, animated: true)
    }

    func performSave(completion: ((Bool) -> Void)? = nil) {
        commitPendingEdits()
        let doc = baseDocument
        doc.save(to: doc.fileURL, for: .forOverwriting) { [weak self] ok in
            if !ok { self?.presentMessage("저장하지 못했습니다", "파일 위치에 쓸 수 있는지 확인하고 다시 시도하세요.") }
            self?.updateChrome()
            completion?(ok)
        }
    }

    // MARK: Export, share, print

    private func exportMenu() -> UIMenu {
        let formats = baseDocument.exportFormats.map { f in
            UIAction(title: f.title) { [weak self] _ in self?.export(f) }
        }
        let share = UIAction(title: "공유…", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in self?.share() }
        let print = UIAction(title: "인쇄…", image: UIImage(systemName: "printer")) { [weak self] _ in self?.printDocument(nil) }
        return UIMenu(children: [
            UIMenu(title: "다른 형식으로 내보내기", image: UIImage(systemName: "doc.badge.arrow.up"), children: formats),
            share, print,
        ])
    }

    @objc func exportDocument(_ sender: Any?) {
        let sheet = UIAlertController(title: "다른 형식으로 내보내기", message: nil, preferredStyle: .actionSheet)
        for f in baseDocument.exportFormats {
            sheet.addAction(UIAlertAction(title: f.title, style: .default) { [weak self] _ in self?.export(f) })
        }
        sheet.addAction(UIAlertAction(title: "취소", style: .cancel))
        sheet.popoverPresentationController?.barButtonItem = exportItem
        present(sheet, animated: true)
    }

    func export(_ format: ExportFormat) {
        commitPendingEdits()
        do {
            let data = try baseDocument.exportData(for: format.ext)
            let url = try GeneratedFiles.temporary(data, name: baseDocument.displayTitle, ext: format.ext)
            let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
            picker.delegate = self
            present(picker, animated: true)
        } catch {
            closeAfterExport = false
            presentError(error)
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        if closeAfterExport {
            closeAfterExport = false
            baseDocument.discardChanges()
            finishClose()
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { closeAfterExport = false }

    private func share() {
        commitPendingEdits()
        let ext = baseDocument.exportFormats.contains { $0.ext == baseDocument.fileExtension } ? baseDocument.fileExtension : (baseDocument.exportFormats.first?.ext ?? "pdf")
        do {
            let url = try GeneratedFiles.temporary(baseDocument.exportData(for: ext), name: baseDocument.displayTitle, ext: ext)
            let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            activity.popoverPresentationController?.barButtonItem = exportItem
            present(activity, animated: true)
        } catch { presentError(error) }
    }

    @objc func printDocument(_ sender: Any?) {
        commitPendingEdits()
        do {
            let data = try baseDocument.pdfData()
            let controller = UIPrintInteractionController.shared
            let info = UIPrintInfo(dictionary: nil)
            info.jobName = baseDocument.displayTitle
            info.outputType = .general
            controller.printInfo = info
            controller.printingItem = data
            controller.present(from: exportItem, animated: true) { _, _, error in
                if let error { self.presentError(error) }
            }
        } catch { presentError(error) }
    }

    @objc func showFind(_ sender: Any?) {}

    // MARK: Close

    @objc func closeDocument(_ sender: Any?) {
        commitPendingEdits()
        let doc = baseDocument
        guard doc.hasUnsavedChanges, !(doc.inPlaceSaveConfirmed && doc.canWriteOriginalFormat) else { finishClose(); return }
        let ext = doc.fileExtension.uppercased()
        let alert = UIAlertController(title: "변경 내용을 저장할까요?", message: "저장하지 않으면 변경 내용이 사라집니다.", preferredStyle: .alert)
        if doc.canWriteOriginalFormat {
            alert.addAction(UIAlertAction(title: "원본(\(ext))에 저장", style: .default) { [weak self] _ in
                doc.inPlaceSaveConfirmed = true
                self?.performSave { ok in if ok { self?.finishClose() } }
            })
        }
        alert.addAction(UIAlertAction(title: "사본으로 저장 후 닫기…", style: .default) { [weak self] _ in
            guard let self, let f = doc.exportFormats.first(where: { $0.ext == "hanx" }) ?? doc.exportFormats.first else { return }
            self.closeAfterExport = true
            self.export(f)
        })
        alert.addAction(UIAlertAction(title: "저장하지 않음", style: .destructive) { [weak self] _ in
            doc.discardChanges()
            self?.finishClose()
        })
        alert.addAction(UIAlertAction(title: "취소", style: .cancel))
        present(alert, animated: true)
    }

    func finishClose() {
        willCloseDocument()
        baseDocument.close { [weak self] _ in
            self?.dismiss(animated: true)
        }
    }
}

extension HanXEditorViewController {
    /// Present a view controller as a popover from a ribbon control (or the export button).
    func presentPopover(_ vc: UIViewController, from source: Any?, size: CGSize? = nil) {
        vc.modalPresentationStyle = .popover
        if let size { vc.preferredContentSize = size }
        PopoverAnchor.apply(vc, source: source ?? exportItem as Any, in: self)
        topmostPresenter.present(vc, animated: true)
    }

    func presentSheet(_ vc: UIViewController, size: CGSize? = nil) {
        let nav = vc as? UINavigationController ?? UINavigationController(rootViewController: vc)
        nav.modalPresentationStyle = .formSheet
        if let size { nav.preferredContentSize = size }
        topmostPresenter.present(nav, animated: true)
    }
}
