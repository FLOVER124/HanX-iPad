import UIKit
import PhotosUI
import UniformTypeIdentifiers

/// Picks an image from Photos or Files (or a movie from Files/Photos) and
/// returns embeddable bytes. One picker is active at a time.
final class MediaPicker: NSObject, PHPickerViewControllerDelegate, UIDocumentPickerDelegate {
    struct Picked { let data: Data; let ext: String; let image: UIImage? }
    enum Kind { case image, movie }

    private static var active: MediaPicker?
    private let kind: Kind
    private let completion: (Picked?) -> Void

    private init(kind: Kind, completion: @escaping (Picked?) -> Void) {
        self.kind = kind
        self.completion = completion
    }

    /// Shows a small menu (사진 보관함 / 파일) anchored at `source`.
    static func pick(_ kind: Kind, from host: UIViewController, source: Any?, completion: @escaping (Picked?) -> Void) {
        let sheet = UIAlertController(title: kind == .image ? "그림 넣기" : "동영상 넣기", message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "사진 보관함", style: .default) { _ in photos(kind, from: host, completion: completion) })
        sheet.addAction(UIAlertAction(title: "파일", style: .default) { _ in files(kind, from: host, completion: completion) })
        sheet.addAction(UIAlertAction(title: "취소", style: .cancel) { _ in completion(nil) })
        PopoverAnchor.apply(sheet, source: source, in: host)
        host.topmostPresenter.present(sheet, animated: true)
    }

    static func photos(_ kind: Kind, from host: UIViewController, completion: @escaping (Picked?) -> Void) {
        var config = PHPickerConfiguration()
        config.filter = kind == .image ? .images : .videos
        config.selectionLimit = 1
        config.preferredAssetRepresentationMode = .compatible
        let picker = PHPickerViewController(configuration: config)
        let coordinator = MediaPicker(kind: kind, completion: completion)
        active = coordinator
        picker.delegate = coordinator
        host.topmostPresenter.present(picker, animated: true)
    }

    static func files(_ kind: Kind, from host: UIViewController, completion: @escaping (Picked?) -> Void) {
        let types: [UTType] = kind == .image ? [.png, .jpeg, .tiff, .gif, .heic, .bmp, .image] : [.mpeg4Movie, .quickTimeMovie, .movie]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        let coordinator = MediaPicker(kind: kind, completion: completion)
        active = coordinator
        picker.delegate = coordinator
        host.topmostPresenter.present(picker, animated: true)
    }

    private func finish(_ picked: Picked?) {
        DispatchQueue.main.async {
            self.completion(picked)
            MediaPicker.active = nil
        }
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider else { finish(nil); return }
        if kind == .movie {
            let type = UTType.movie.identifier
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                guard let url, let data = try? Data(contentsOf: url) else { self.finish(nil); return }
                let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension.lowercased()
                self.finish(Picked(data: data, ext: ext, image: nil))
            }
            return
        }
        guard provider.canLoadObject(ofClass: UIImage.self) else { finish(nil); return }
        provider.loadObject(ofClass: UIImage.self) { object, _ in
            guard let image = object as? UIImage else { self.finish(nil); return }
            let normalized = image.normalizedOrientation()
            let hasAlpha = normalized.cgImage.map { [.first, .last, .premultipliedFirst, .premultipliedLast].contains($0.alphaInfo) } ?? false
            guard let encoded = normalized.embeddableData(preferJPEG: !hasAlpha) else { self.finish(nil); return }
            self.finish(Picked(data: encoded.0, ext: encoded.1, image: normalized))
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first, let data = try? Data(contentsOf: url) else { finish(nil); return }
        let ext = url.pathExtension.lowercased()
        if kind == .movie { finish(Picked(data: data, ext: ext.isEmpty ? "mp4" : ext, image: nil)); return }
        guard let image = UIImage(data: data) else { finish(nil); return }
        if ["png", "jpg", "jpeg", "gif"].contains(ext) {
            finish(Picked(data: data, ext: ext == "jpg" ? "jpeg" : ext, image: image))
        } else if let encoded = image.normalizedOrientation().embeddableData() {
            finish(Picked(data: encoded.0, ext: encoded.1, image: image))
        } else { finish(nil) }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish(nil) }
}

extension UIImage {
    /// Bakes EXIF orientation into the pixels (documents store upright bitmaps).
    func normalizedOrientation() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in draw(in: CGRect(origin: .zero, size: size)) }
    }
}
