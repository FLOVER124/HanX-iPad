import UIKit

extension Notification.Name {
    static let slidesChanged = Notification.Name("HanXSlidesChanged")
}

/// PPTX / HanX presentation. Every edit snapshots the slides and media so
/// undo restores exactly (like the macOS SlideDocument).
final class SlideFileDocument: HanXBaseDocument {
    private(set) var pres = Presentation.blank()
    /// Edited pictures remember their original for "원본 복원" (this session).
    private var imageOriginals: [String: (id: String, image: ImageData, region: CGRect)] = [:]

    override var exportFormats: [ExportFormat] { ExportFormat.presentation }

    override func load(fromContents contents: Any, ofType typeName: String?) throws {
        guard let data = contents as? Data else { throw HanXError.message("프레젠테이션을 읽을 수 없습니다.") }
        do {
            let loaded = fileExtension == "hanx"
                ? try PPTXReader(zip: HanXFile.payload(data, expecting: .presentation)).read()
                : try PPTXReader(zip: ZipReader(data: data)).read()
            if loaded.slides.isEmpty { loaded.slides = [loaded.titleSlide()] }
            pres = loaded
            imageOriginals = [:]
        } catch {
            recordLoadError(error)
            throw error
        }
    }

    override func exportData(for ext: String) throws -> Data {
        NotificationCenter.default.post(name: .slidesCommitEditing, object: self)
        switch ext {
        case "hanx": return HanXFile.encode(.presentation, payload: PPTXWriter.write(pres))
        case "pdf": return SlideRenderer.pdf(pres)
        default: return PPTXWriter.write(pres)
        }
    }

    override func pdfData() -> Data { SlideRenderer.pdf(pres) }

    // MARK: Undoable edits

    private struct Snapshot { let slides: [Slide]; let images: [String: ImageData]; let width: Double; let height: Double }
    private func snapshot() -> Snapshot { Snapshot(slides: pres.slides, images: pres.images, width: pres.width, height: pres.height) }

    private func restore(_ s: Snapshot, name: String) {
        let inverse = snapshot()
        pres.slides = s.slides
        pres.images = s.images
        pres.width = s.width
        pres.height = s.height
        undoManager.registerUndo(withTarget: self) { $0.restore(inverse, name: name) }
        undoManager.setActionName(name)
        NotificationCenter.default.post(name: .slidesChanged, object: self)
    }

    func edit(_ name: String, _ change: (Presentation) -> Void) {
        let before = snapshot()
        change(pres)
        undoManager.registerUndo(withTarget: self) { $0.restore(before, name: name) }
        undoManager.setActionName(name)
        NotificationCenter.default.post(name: .slidesChanged, object: self)
    }

    func addImage(_ data: Data, ext: String) -> String {
        var key: String
        repeat { key = "media/\(UUID().uuidString).\(ext)" } while pres.images[key] != nil
        pres.images[key] = ImageData(name: "image.\(ext)", data: data)
        return key
    }

    // MARK: Picture editing (crop, adjustments, background removal)

    func originalImage(_ imageID: String) -> ImageData? {
        imageOriginals[imageID]?.image ?? pres.images[imageID]
    }

    @discardableResult
    func replaceImage(slide index: Int, shapeID: Int, expectedImageID: String, png: Data, actionName: String, crop: CGRect? = nil) -> Bool {
        guard pres.slides.indices.contains(index),
              let shape = pres.slides[index].shapes.firstIndex(where: { $0.id == shapeID && $0.kind == .image && !$0.locked && $0.imageID == expectedImageID }),
              let source = pres.images[expectedImageID] else { return false }
        let key = "edited-image/\(UUID().uuidString).png"
        let original = imageOriginals[expectedImageID] ?? (id: expectedImageID, image: source, region: SlideImageCrop.full)
        let region = crop.map { SlideImageCrop.composed(original.region, $0) } ?? original.region
        imageOriginals[key] = (original.id, original.image, region)
        edit(actionName) { p in
            p.images[key] = ImageData(name: "edited-image.png", data: png)
            if let crop { p.slides[index].shapes[shape].frame = SlideImageCrop.frame(for: p.slides[index].shapes[shape], rect: crop) }
            p.slides[index].shapes[shape].imageID = key
        }
        return true
    }

    @discardableResult
    func restoreImage(slide index: Int, shapeID: Int) -> Bool {
        guard pres.slides.indices.contains(index),
              let shape = pres.slides[index].shapes.firstIndex(where: { $0.id == shapeID && $0.kind == .image && !$0.locked }),
              let imageID = pres.slides[index].shapes[shape].imageID,
              let original = imageOriginals[imageID] else { return false }
        edit("그림 원본 복원") { p in
            p.images[original.id] = original.image
            if original.region != SlideImageCrop.full {
                p.slides[index].shapes[shape].frame = SlideImageCrop.frame(for: p.slides[index].shapes[shape], rect: original.region, restoring: true)
            }
            p.slides[index].shapes[shape].imageID = original.id
        }
        return true
    }

    func canRestoreImage(_ imageID: String?) -> Bool { imageID.map { imageOriginals[$0] != nil } ?? false }
}

extension Notification.Name {
    static let slidesCommitEditing = Notification.Name("HanXSlidesCommitEditing")
}
