import Foundation

/// Version 1: UTF-8 signature and kind, each terminated by LF, followed by
/// the corresponding zipped document payload. The filename is never a type hint.
enum HanXFile {
    static let type = "org.studentsview.hanx.file"
    enum Kind: String, CaseIterable {
        case document, presentation, spreadsheet
        var part: String {
            switch self {
            case .document: return "word/document.xml"
            case .presentation: return "ppt/presentation.xml"
            case .spreadsheet: return "xl/workbook.xml"
            }
        }
        var header: Data { Data("HanX/1\n\(rawValue)\n".utf8) }
    }

    static func kind(in prefix: Data) throws -> Kind {
        guard let kind = Kind.allCases.first(where: { prefix.starts(with: $0.header) }) else {
            throw FormatError.invalid("지원하지 않는 HanX 파일 형식 또는 버전입니다.")
        }
        return kind
    }
    static func kind(at url: URL) throws -> Kind {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try kind(in: handle.read(upToCount: 64) ?? Data())
    }
    static func encode(_ kind: Kind, payload: Data) -> Data { kind.header + payload }

    static func payload(_ data: Data, expecting expected: Kind) throws -> ZipReader {
        guard try kind(in: data) == expected else { throw FormatError.invalid("HanX 문서 종류가 일치하지 않습니다.") }
        let zip = try ZipReader(data: Data(data.dropFirst(expected.header.count)))
        guard zip.has(expected.part) else { throw FormatError.invalid("HanX 문서 내용과 종류가 일치하지 않습니다.") }
        return zip
    }
}
