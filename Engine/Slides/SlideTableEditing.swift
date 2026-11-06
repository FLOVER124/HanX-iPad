import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum SlideTableEditing {
    static func text(_ cell:TableCell)->String {
        cell.blocks.compactMap { if case .paragraph(let p)=$0 { return p.plainText }; return nil }.joined(separator:"\n")
    }
    static func settingText(_ table:Table,row:Int,column:Int,text:String)->Table {
        guard table.rows.indices.contains(row),table.rows[row].indices.contains(column),!table.rows[row][column].isMergedAway else { return table }
        var result=table
        let cell=table.rows[row][column]
        guard self.text(cell) != text else { return table }
        var paragraphs=cell.blocks.compactMap { if case .paragraph(let p)=$0 { return p }; return nil }
        if paragraphs.isEmpty { paragraphs=[Presentation.textParagraph("",size:16)] }
        struct Glyph {
            var value:Character
            var style:CharProps
            var paragraph:Int
            var separator=false
            var special:Int?=nil
        }
        var old:[Glyph]=[]
        for (pi,p) in paragraphs.enumerated() {
            if pi>0 { old.append(Glyph(value:"\n",style:p.markProps,paragraph:pi,separator:true)) }
            for (ii,inline) in p.inlines.enumerated() {
                var style=p.markProps
                var special:Int?=ii
                switch inline {
                case .text(_,let c): style=c; special=nil
                case .tab(let c),.lineBreak(let c),.field(_,let c): style=c
                default: break
                }
                let value=Paragraph(inlines:[inline]).plainText
                old += value.map { Glyph(value:$0,style:style,paragraph:pi,special:special) }
            }
        }
        // An individual editor change replaces one contiguous range. Retain
        // the untouched prefix/suffix, including their paragraph and run styles.
        let chars=Array(text)
        var prefix=0,suffix=0
        while prefix<min(old.count,chars.count),old[prefix].value == chars[prefix] { prefix += 1 }
        while suffix<min(old.count-prefix,chars.count-prefix),old[old.count-1-suffix].value == chars[chars.count-1-suffix] { suffix += 1 }
        let anchor:Glyph
        if prefix>0,!old[prefix-1].separator { anchor=old[prefix-1] }
        else if prefix<old.count { anchor=old[prefix] }
        else { anchor=Glyph(value:" ",style:paragraphs.last!.markProps,paragraph:paragraphs.count-1) }
        let inserted=chars[prefix..<(chars.count-suffix)].map { Glyph(value:$0,style:anchor.style,paragraph:anchor.paragraph,separator:$0 == "\n") }
        let updated=Array(old.prefix(prefix))+inserted+Array(old.suffix(suffix))
        var groups:[[Glyph]]=[[]],origins=[0]
        for glyph in updated {
            if glyph.separator { groups.append([]); origins.append(glyph.paragraph) }
            else { groups[groups.count-1].append(glyph) }
        }
        result.rows[row][column].blocks=groups.enumerated().map { index,glyphs in
            let source=glyphs.first?.paragraph ?? origins[index]
            var p=paragraphs[source]
            if String(glyphs.map(\.value)) == p.plainText && glyphs.allSatisfy({$0.paragraph == source}) { return .paragraph(p) }
            p.inlines=[]
            func appendText(_ value:String,_ style:CharProps) {
                if let last=p.inlines.last,case .text(let s,let c)=last,c == style { p.inlines[p.inlines.count-1] = .text(s+value,c) }
                else { p.inlines.append(.text(value,style)) }
            }
            var i=0
            while i<glyphs.count {
                let g=glyphs[i]
                if let special=g.special {
                    var end=i+1
                    while end<glyphs.count,glyphs[end].special == special,glyphs[end].paragraph == g.paragraph { end += 1 }
                    let inline=paragraphs[g.paragraph].inlines[special]
                    let value=String(glyphs[i..<end].map(\.value))
                    if value == Paragraph(inlines:[inline]).plainText { p.inlines.append(inline) }
                    else { appendText(value,g.style) }
                    i=end
                } else { appendText(String(g.value),g.style); i += 1 }
            }
            return .paragraph(p)
        }
        return result
    }
}
