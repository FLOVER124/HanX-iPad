import Foundation

enum DocumentTemplates {
    static let names = ["편지지", "라벨 2열 × 7행"]
    static func make(_ name: String) -> UDocument? {
        guard ["letter", "labels"].contains(name) else { return nil }
        let document = UDocument()
        document.source = .docx
        var section = Section()
        func paragraph(_ text: String) -> Paragraph {
            var p = Paragraph()
            var style = CharProps(); style.size = 11
            p.inlines = [.text(text, style)]
            return p
        }
        if name == "letter" {
            var heading = paragraph("보내는 사람")
            heading.props.bottomBorder = .thin
            section.header = [.paragraph(heading)]
            section.footer = [.paragraph(paragraph("연락처"))]
            section.blocks = ["받는 사람", "날짜", "", "제목", "", "내용을 입력하세요.", "", "보내는 사람"].map { .paragraph(paragraph($0)) }
        } else {
            section.page.marginLeft = 36; section.page.marginRight = 36
            section.page.marginTop = 36; section.page.marginBottom = 36
            let width = section.page.contentWidth / 2
            var table = Table(); table.columnWidths = [width,width]
            table.rows = (0..<7).map { _ in
                (0..<2).map { _ in
                    var cell = TableCell()
                    cell.blocks = [.paragraph(paragraph("이름")), .paragraph(paragraph("주소"))]
                    cell.height = 100
                    return cell
                }
            }
            section.blocks = [.table(table), .paragraph(paragraph(""))]
        }
        document.sections = [section]
        return document
    }
}
