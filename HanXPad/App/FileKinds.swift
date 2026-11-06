import UIKit
import UniformTypeIdentifiers

enum EditorKind {
    case document, spreadsheet, presentation, pdf
}

/// File types the app reads and writes. Identifiers match the macOS app so
/// documents move between both apps (and the Files app) unchanged.
enum FileKinds {
    static let hanx = UTType(exportedAs: "org.studentsview.hanx.file", conformingTo: .data)
    static let hwp = UTType(importedAs: "com.haansoft.HancomOfficeViewer.mac.hwp", conformingTo: .data)
    static let hwt = UTType(importedAs: "com.haansoft.HancomOfficeViewer.mac.hwt", conformingTo: .data)
    static let hwpx = UTType(importedAs: "com.haansoft.HancomOfficeViewer.mac.hwpx", conformingTo: .zip)
    static let markdown = UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)
    static let docx = UTType(importedAs: "org.openxmlformats.wordprocessingml.document", conformingTo: .data)
    static let dotx = UTType(importedAs: "org.openxmlformats.wordprocessingml.template", conformingTo: .data)
    static let xlsx = UTType(importedAs: "org.openxmlformats.spreadsheetml.sheet", conformingTo: .data)
    static let pptx = UTType(importedAs: "org.openxmlformats.presentationml.presentation", conformingTo: .data)

    static var readable: [UTType] {
        [hanx, hwp, hwt, hwpx, docx, dotx, xlsx, pptx, .pdf, .commaSeparatedText, .tabSeparatedText, .plainText, markdown, .html, .rtf]
    }

    static func kind(for url: URL) -> EditorKind? {
        switch url.pathExtension.lowercased() {
        case "hwp", "hwt", "hwpx", "docx", "dotx", "txt", "text", "md", "markdown", "rtf", "html", "htm": return .document
        case "xlsx", "csv", "tsv", "tab": return .spreadsheet
        case "pptx": return .presentation
        case "pdf": return .pdf
        case "hanx":
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            var coordinated: HanXFile.Kind?
            var error: NSError?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { readURL in
                coordinated = try? HanXFile.kind(at: readURL)
            }
            switch coordinated {
            case .document: return .document
            case .spreadsheet: return .spreadsheet
            case .presentation: return .presentation
            case nil: return nil
            }
        default: return nil
        }
    }

    static func type(forExtension ext: String) -> UTType {
        switch ext.lowercased() {
        case "hanx": return hanx
        case "hwp": return hwp
        case "hwpx": return hwpx
        case "docx": return docx
        case "xlsx": return xlsx
        case "pptx": return pptx
        case "md": return markdown
        default: return UTType(filenameExtension: ext) ?? .data
        }
    }
}

/// Export targets shown in the "다른 형식으로 내보내기" menus.
struct ExportFormat {
    let title: String
    let ext: String
    static let document = [
        ExportFormat(title: "HanX 파일 (.hanx)", ext: "hanx"), ExportFormat(title: "한글 표준 문서 (.hwpx)", ext: "hwpx"),
        ExportFormat(title: "한글 문서 (.hwp)", ext: "hwp"), ExportFormat(title: "Word 문서 (.docx)", ext: "docx"),
        ExportFormat(title: "PDF (.pdf)", ext: "pdf"), ExportFormat(title: "웹 페이지 (.html)", ext: "html"),
        ExportFormat(title: "서식 있는 텍스트 (.rtf)", ext: "rtf"), ExportFormat(title: "Markdown (.md)", ext: "md"),
        ExportFormat(title: "일반 텍스트 (.txt)", ext: "txt"),
    ]
    static let spreadsheet = [
        ExportFormat(title: "HanX 파일 (.hanx)", ext: "hanx"), ExportFormat(title: "Excel 통합 문서 (.xlsx)", ext: "xlsx"),
        ExportFormat(title: "CSV - 현재 시트 (.csv)", ext: "csv"), ExportFormat(title: "TSV - 현재 시트 (.tsv)", ext: "tsv"),
        ExportFormat(title: "웹 페이지 (.html)", ext: "html"), ExportFormat(title: "PDF (.pdf)", ext: "pdf"),
    ]
    static let presentation = [
        ExportFormat(title: "HanX 파일 (.hanx)", ext: "hanx"), ExportFormat(title: "PowerPoint (.pptx)", ext: "pptx"),
        ExportFormat(title: "PDF (.pdf)", ext: "pdf"),
    ]
    static let pdf = [ExportFormat(title: "PDF 복사본 (.pdf)", ext: "pdf")]
}
