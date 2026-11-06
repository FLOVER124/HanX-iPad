import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Native editing data must retain properties not represented by PPTX export
/// (such as locked master decoration and original shape IDs).
enum SlideClipboard {
    static func remappingMedia(_ slides:[Slide],ids:[String:String])->[Slide] {
        func paragraph(_ value:Paragraph)->Paragraph {
            var result=value
            result.inlines=value.inlines.map { inline in
                if case .image(let id,let w,let h)=inline { return .image(id:ids[id] ?? id,width:w,height:h) }
                return inline
            }
            return result
        }
        func table(_ value:Table)->Table {
            var result=value
            result.rows=value.rows.map { row in row.map { cell in
                var result=cell
                result.blocks=cell.blocks.map { block in
                    switch block {
                    case .paragraph(let p): return .paragraph(paragraph(p))
                    case .table(let t): return .table(table(t))
                    }
                }
                return result
            } }
            return result
        }
        return slides.map { slide in
            var result=slide
            if let id=slide.backgroundImage { result.backgroundImage=ids[id] ?? id }
            result.shapes=slide.shapes.map { shape in
                var result=shape
                if let id=shape.imageID { result.imageID=ids[id] ?? id }
                if let id=shape.videoID { result.videoID=ids[id] ?? id }
                result.paragraphs=shape.paragraphs.map(paragraph)
                if let t=shape.table { result.table=table(t) }
                return result
            }
            return result
        }
    }
    private struct Payload:Codable {
        var version=1
        var width:Double
        var height:Double
        var slides:[Slide]
        var images:[String:ImageData]
    }
    static func encode(_ source:Presentation) throws ->Data {
        var used=Set<String>()
        func paragraph(_ p:Paragraph) { for inline in p.inlines { if case .image(let id,_,_)=inline { used.insert(id) } } }
        func blocks(_ list:[Block]) {
            for block in list { switch block {
            case .paragraph(let p): paragraph(p)
            case .table(let t): for row in t.rows { for cell in row { blocks(cell.blocks) } }
            } }
        }
        for slide in source.slides {
            if let id=slide.backgroundImage { used.insert(id) }
            for shape in slide.shapes {
                if let id=shape.imageID { used.insert(id) }
                if let id=shape.videoID { used.insert(id) }
                shape.paragraphs.forEach(paragraph)
                if let table=shape.table { for row in table.rows { for cell in row { blocks(cell.blocks) } } }
            }
        }
        let encoder=PropertyListEncoder(); encoder.outputFormat = .binary
        return try encoder.encode(Payload(width:source.width,height:source.height,slides:source.slides,images:source.images.filter { used.contains($0.key) }))
    }
    static func decode(_ data:Data)->Presentation? {
        if let payload=try? PropertyListDecoder().decode(Payload.self,from:data),payload.version == 1,payload.width.isFinite,payload.height.isFinite,payload.width>0,payload.height>0 {
            let p=Presentation(); p.width=payload.width; p.height=payload.height; p.slides=payload.slides; p.images=payload.images; return p
        }
        // Read clipboards written by earlier HanX versions.
        guard let zip=try? ZipReader(data:data) else { return nil }
        return try? PPTXReader(zip:zip).read()
    }
}
