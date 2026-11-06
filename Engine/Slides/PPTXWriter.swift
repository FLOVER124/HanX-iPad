import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Writes a self-contained PresentationML package: one blank layout, one
/// master, a full theme, and slides whose shapes carry explicit geometry and
/// fully specified text properties (no reliance on placeholder inheritance).
enum PPTXWriter {
    static let nsA = "http://schemas.openxmlformats.org/drawingml/2006/main"
    static let nsP = "http://schemas.openxmlformats.org/presentationml/2006/main"
    static let nsR = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    static let relBase = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    static func write(_ pres: Presentation) -> Data {
        let z = ZipWriter()
        var media: [String: String] = [:]     // image id → media file name
        var mediaCount = 0
        var slideXML: [String] = []
        var slideRels: [String] = []

        let hasNotes=pres.slides.contains { !$0.notes.isEmpty }
        for (slideIndex,slide) in pres.slides.enumerated() {
            var rels = "<Relationship Id=\"rId1\" Type=\"\(relBase)/slideLayout\" Target=\"../slideLayouts/slideLayout1.xml\"/>"
            var relN = 1
            var imageRel: [String: String] = [:]
            func rel(forImage id: String) -> String? {
                guard let img = pres.images[id] else { return nil }
                if let r = imageRel[id] { return r }
                let name: String
                if let existing = media[id] { name = existing } else {
                    mediaCount += 1
                    var ext = img.ext
                    if !["png", "jpg", "jpeg", "gif", "bmp", "tif", "tiff", "emf", "wmf"].contains(ext) { ext = "png" }
                    name = "image\(mediaCount).\(ext)"
                    media[id] = name
                    z.add("ppt/media/\(name)", img.data, compress: false)
                }
                relN += 1
                let r = "rId\(relN)"
                rels += "<Relationship Id=\"\(r)\" Type=\"\(relBase)/image\" Target=\"../media/\(name)\"/>"
                imageRel[id] = r
                return r
            }
            func movieRelationships(_ key: String) -> (video: String, media: String)? {
                guard let asset = pres.images[key] else { return nil }
                let filename: String
                if let existing = media[key] { filename = existing }
                else {
                    mediaCount += 1
                    let supported = ["mp4","m4v","mov","webm","avi","wmv","mpeg","mpg"]
                    let ext = supported.contains(asset.ext) ? asset.ext : "bin"
                    filename = "video\(mediaCount).\(ext)"
                    media[key] = filename
                    z.add("ppt/media/\(filename)", asset.data, compress: false)
                }
                func relationship(_ type: String) -> String {
                    relN += 1
                    let id = "rId\(relN)"
                    rels += "<Relationship Id=\"\(id)\" Type=\"\(type)\" Target=\"../media/\(filename)\"/>"
                    return id
                }
                return (relationship(relBase + "/video"), relationship("http://schemas.microsoft.com/office/2007/relationships/media"))
            }
            var movieTargets: [Int] = []
            var tree = ""
            var nextID = 2
            var xmlID: [Int: Int] = [:]
            for s in slide.shapes {
                nextID += 1
                xmlID[s.id] = nextID
                let movie = s.videoID.flatMap(movieRelationships)
                if movie != nil { movieTargets.append(nextID) }
                tree += shapeXML(s, id: nextID, imageRel: rel(forImage:), movie: movie)
            }
            var bg = ""
            if let id = slide.backgroundImage, let r = rel(forImage: id) {
                bg = "<p:bg><p:bgPr><a:blipFill><a:blip r:embed=\"\(r)\"/><a:stretch><a:fillRect/></a:stretch></a:blipFill><a:effectLst/></p:bgPr></p:bg>"
            } else if let start = slide.background, let end = slide.backgroundEnd {
                let middle = slide.backgroundMiddle.map {
                    #"<a:gs pos="\#(Int((slide.middleFraction * 100000).rounded()))"><a:srgbClr val="\#($0.hex)"/></a:gs>"#
                } ?? ""
                bg = """
                <p:bg><p:bgPr><a:gradFill><a:gsLst><a:gs pos="0"><a:srgbClr val="\(start.hex)"/></a:gs>\(middle)<a:gs pos="100000"><a:srgbClr val="\(end.hex)"/></a:gs></a:gsLst><a:lin ang="\(Int((slide.gradientAngle * 60000).rounded()) % 21600000)" scaled="0"/></a:gradFill><a:effectLst/></p:bgPr></p:bg>
                """
            } else if let c = slide.background {
                bg = "<p:bg><p:bgPr><a:solidFill><a:srgbClr val=\"\(c.hex)\"/></a:solidFill><a:effectLst/></p:bgPr></p:bg>"
            }
            if !slide.notes.isEmpty {
                let n=slideIndex+1
                relN += 1
                rels += "<Relationship Id=\"rId\(relN)\" Type=\"\(relBase)/notesSlide\" Target=\"../notesSlides/notesSlide\(n).xml\"/>"
                let paragraphs=slide.notes.components(separatedBy:"\n").map { paragraphXML(Presentation.textParagraph($0,size:12)) }.joined()
                z.add("ppt/notesSlides/notesSlide\(n).xml","""
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?><p:notes xmlns:a="\(nsA)" xmlns:r="\(nsR)" xmlns:p="\(nsP)"><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>
                <p:sp><p:nvSpPr><p:cNvPr id="2" name="Notes Text"/><p:cNvSpPr txBox="1"/><p:nvPr><p:ph type="body" idx="1"/></p:nvPr></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/>\(paragraphs)</p:txBody></p:sp></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:notes>
                """)
                z.add("ppt/notesSlides/_rels/notesSlide\(n).xml.rels","<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"\(relBase)/notesMaster\" Target=\"../notesMasters/notesMaster1.xml\"/><Relationship Id=\"rId2\" Type=\"\(relBase)/slide\" Target=\"../slides/slide\(n).xml\"/></Relationships>")
            }
            slideXML.append("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?><p:sld xmlns:a="\(nsA)" xmlns:r="\(nsR)" xmlns:p="\(nsP)"><p:cSld>\(bg)<p:spTree>\
            <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/>\
            <a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>\(tree)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>\
            \(transitionXML(slide.transition))\(timingXML(slide.animations, ids: xmlID, movies: movieTargets))</p:sld>
            """)
            slideRels.append("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(rels)</Relationships>")
        }

        var overrides = ""
        for i in slideXML.indices {
            overrides += "<Override PartName=\"/ppt/slides/slide\(i + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>"
            if !pres.slides[i].notes.isEmpty { overrides += "<Override PartName=\"/ppt/notesSlides/notesSlide\(i+1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.notesSlide+xml\"/>" }
        }
        if hasNotes { overrides += "<Override PartName=\"/ppt/notesMasters/notesMaster1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.notesMaster+xml\"/>" }
        let movieExtensions = Set(media.values.filter { $0.hasPrefix("video") }.map { ($0 as NSString).pathExtension })
        let movieTypes = ["mp4":"video/mp4","m4v":"video/mp4","mov":"video/quicktime","webm":"video/webm","avi":"video/x-msvideo","wmv":"video/x-ms-wmv","mpeg":"video/mpeg","mpg":"video/mpeg"]
        for ext in movieExtensions.sorted() {
            overrides += "<Default Extension=\"\(ext)\" ContentType=\"\(movieTypes[ext] ?? "application/octet-stream")\"/>"
        }
        z.add("[Content_Types].xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/>\
        <Default Extension="png" ContentType="image/png"/><Default Extension="jpg" ContentType="image/jpeg"/><Default Extension="jpeg" ContentType="image/jpeg"/>\
        <Default Extension="gif" ContentType="image/gif"/><Default Extension="bmp" ContentType="image/bmp"/><Default Extension="tif" ContentType="image/tiff"/>\
        <Default Extension="tiff" ContentType="image/tiff"/><Default Extension="emf" ContentType="image/x-emf"/><Default Extension="wmf" ContentType="image/x-wmf"/>\
        <Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>\
        <Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>\
        <Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>\
        <Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>\
        <Override PartName="/ppt/presProps.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presProps+xml"/>\
        <Override PartName="/ppt/viewProps.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.viewProps+xml"/>\
        <Override PartName="/ppt/tableStyles.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.tableStyles+xml"/>\
        <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>\
        <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>\(overrides)</Types>
        """)
        z.add("_rels/.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="\(relBase)/officeDocument" Target="ppt/presentation.xml"/>\
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>\
        <Relationship Id="rId3" Type="\(relBase)/extended-properties" Target="docProps/app.xml"/></Relationships>
        """)
        z.add("docProps/core.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:creator>HanX</dc:creator></cp:coreProperties>")
        z.add("docProps/app.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Properties xmlns=\"http://schemas.openxmlformats.org/officeDocument/2006/extended-properties\"><Application>HanX</Application><Slides>\(pres.slides.count)</Slides></Properties>")

        var sldIds = "", presRels = "<Relationship Id=\"rId1\" Type=\"\(relBase)/slideMaster\" Target=\"slideMasters/slideMaster1.xml\"/>"
        for i in slideXML.indices {
            sldIds += "<p:sldId id=\"\(256 + i)\" r:id=\"rId\(i + 10)\"/>"
            presRels += "<Relationship Id=\"rId\(i + 10)\" Type=\"\(relBase)/slide\" Target=\"slides/slide\(i + 1).xml\"/>"
        }
        presRels += "<Relationship Id=\"rId2\" Type=\"\(relBase)/theme\" Target=\"theme/theme1.xml\"/>"
        presRels += "<Relationship Id=\"rId3\" Type=\"\(relBase)/presProps\" Target=\"presProps.xml\"/>"
        presRels += "<Relationship Id=\"rId4\" Type=\"\(relBase)/viewProps\" Target=\"viewProps.xml\"/>"
        presRels += "<Relationship Id=\"rId5\" Type=\"\(relBase)/tableStyles\" Target=\"tableStyles.xml\"/>"
        if hasNotes { presRels += "<Relationship Id=\"rId6\" Type=\"\(relBase)/notesMaster\" Target=\"notesMasters/notesMaster1.xml\"/>" }
        z.add("ppt/presentation.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?><p:presentation xmlns:a="\(nsA)" xmlns:r="\(nsR)" xmlns:p="\(nsP)" saveSubsetFonts="1">\
        <p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>\(hasNotes ? "<p:notesMasterIdLst><p:notesMasterId r:id=\"rId6\"/></p:notesMasterIdLst>" : "")<p:sldIdLst>\(sldIds)</p:sldIdLst>\
        <p:sldSz cx="\(DrawingML.emu(pres.width))" cy="\(DrawingML.emu(pres.height))"/><p:notesSz cx="6858000" cy="9144000"/>\
        <p:defaultTextStyle><a:defPPr><a:defRPr lang="ko-KR"/></a:defPPr></p:defaultTextStyle></p:presentation>
        """)
        z.add("ppt/_rels/presentation.xml.rels", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(presRels)</Relationships>")
        z.add("ppt/presProps.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><p:presentationPr xmlns:a=\"\(nsA)\" xmlns:r=\"\(nsR)\" xmlns:p=\"\(nsP)\"/>")
        z.add("ppt/viewProps.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><p:viewPr xmlns:a=\"\(nsA)\" xmlns:r=\"\(nsR)\" xmlns:p=\"\(nsP)\"><p:normalViewPr><p:restoredLeft sz=\"15620\"/><p:restoredTop sz=\"94660\"/></p:normalViewPr><p:gridSpacing cx=\"76200\" cy=\"76200\"/></p:viewPr>")
        z.add("ppt/tableStyles.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><a:tblStyleLst xmlns:a=\"\(nsA)\" def=\"{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}\"/>")
        let emptyTree = "<p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/><a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"0\" cy=\"0\"/></a:xfrm></p:grpSpPr></p:spTree>"
        if hasNotes {
            z.add("ppt/notesMasters/notesMaster1.xml","<p:notesMaster xmlns:a=\"\(nsA)\" xmlns:r=\"\(nsR)\" xmlns:p=\"\(nsP)\"><p:cSld>\(emptyTree)</p:cSld><p:clrMap bg1=\"lt1\" tx1=\"dk1\" bg2=\"lt2\" tx2=\"dk2\" accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" hlink=\"hlink\" folHlink=\"folHlink\"/><p:notesStyle><a:defPPr><a:defRPr lang=\"ko-KR\" sz=\"1200\"/></a:defPPr></p:notesStyle></p:notesMaster>")
            z.add("ppt/notesMasters/_rels/notesMaster1.xml.rels","<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"\(relBase)/theme\" Target=\"../theme/theme1.xml\"/></Relationships>")
        }
        z.add("ppt/slideMasters/slideMaster1.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?><p:sldMaster xmlns:a="\(nsA)" xmlns:r="\(nsR)" xmlns:p="\(nsP)"><p:cSld>\
        <p:bg><p:bgRef idx="1001"><a:schemeClr val="bg1"/></p:bgRef></p:bg>\(emptyTree)</p:cSld>\
        <p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>\
        <p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst><p:txStyles>\
        <p:titleStyle><a:lvl1pPr algn="l"><a:defRPr sz="4400" kern="1200"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill><a:latin typeface="+mj-lt"/><a:ea typeface="+mj-ea"/><a:cs typeface="+mj-cs"/></a:defRPr></a:lvl1pPr></p:titleStyle>\
        <p:bodyStyle><a:lvl1pPr marL="0" indent="0"><a:buNone/><a:defRPr sz="2400" kern="1200"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill><a:latin typeface="+mn-lt"/><a:ea typeface="+mn-ea"/><a:cs typeface="+mn-cs"/></a:defRPr></a:lvl1pPr></p:bodyStyle>\
        <p:otherStyle><a:defPPr><a:defRPr lang="ko-KR"/></a:defPPr></p:otherStyle></p:txStyles></p:sldMaster>
        """)
        z.add("ppt/slideMasters/_rels/slideMaster1.xml.rels", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"\(relBase)/slideLayout\" Target=\"../slideLayouts/slideLayout1.xml\"/><Relationship Id=\"rId2\" Type=\"\(relBase)/theme\" Target=\"../theme/theme1.xml\"/></Relationships>")
        z.add("ppt/slideLayouts/slideLayout1.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><p:sldLayout xmlns:a=\"\(nsA)\" xmlns:r=\"\(nsR)\" xmlns:p=\"\(nsP)\" type=\"blank\" preserve=\"1\"><p:cSld name=\"빈 화면\">\(emptyTree)</p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>")
        z.add("ppt/slideLayouts/_rels/slideLayout1.xml.rels", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"\(relBase)/slideMaster\" Target=\"../slideMasters/slideMaster1.xml\"/></Relationships>")
        z.add("ppt/theme/theme1.xml", theme)
        for (i, x) in slideXML.enumerated() {
            z.add("ppt/slides/slide\(i + 1).xml", x)
            z.add("ppt/slides/_rels/slide\(i + 1).xml.rels", slideRels[i])
        }
        return z.finish()
    }

    // MARK: Transitions & animations

    static func transitionXML(_ t: SlideTransition) -> String {
        guard t.kind != .none || t.advanceAfter != nil || !t.advanceOnClick else { return "" }
        let spd = t.duration < 0.6 ? "fast" : t.duration < 1.1 ? "med" : "slow"
        var attrs = " spd=\"\(spd)\" advClick=\"\(t.advanceOnClick ? 1 : 0)\" xmlns:p14=\"http://schemas.microsoft.com/office/powerpoint/2010/main\" p14:dur=\"\(Int((t.duration * 1000).rounded()))\" xmlns:mc=\"http://schemas.openxmlformats.org/markup-compatibility/2006\" mc:Ignorable=\"p14\""
        if let a = t.advanceAfter { attrs += " advTm=\"\(Int(a * 1000))\"" }
        let dir = ["left": "r", "right": "l", "top": "d", "bottom": "u"][t.direction.rawValue]!
        let body: String
        switch t.kind {
        case .none: body = ""
        case .fade: body = "<p:fade/>"
        case .push: body = "<p:push dir=\"\(dir)\"/>"
        case .wipe: body = "<p:wipe dir=\"\(dir)\"/>"
        case .cover: body = "<p:cover dir=\"\(dir)\"/>"
        case .pull: body = "<p:pull dir=\"\(dir)\"/>"
        case .split: body = "<p:split orient=\"\(t.vertical ? "vert" : "horz")\" dir=\"\(t.inward ? "in" : "out")\"/>"
        case .zoom: body = "<p:zoom dir=\"\(t.inward ? "in" : "out")\"/>"
        case .dissolve: body = "<p:dissolve/>"
        case .cut: body = "<p:cut/>"
        case .blinds, .comb, .randomBar: body = "<p:\(t.kind.rawValue) dir=\"\(t.vertical ? "vert" : "horz")\"/>"
        case .checker: body = "<p:checker dir=\"\(t.vertical ? "vert" : "horz")\"/>"
        case .strips: body = "<p:strips dir=\"\([AnimDirection.left:"lu",.top:"ru",.right:"rd",.bottom:"ld"][t.direction]!)\"/>"
        case .wheel: body = "<p:wheel spokes=\"4\"/>"
        case .circle, .diamond, .plus, .wedge, .newsflash: body = "<p:\(t.kind.rawValue)/>"
        }
        return "<p:transition\(attrs)>\(body)</p:transition>"
    }

    /// Builds the PresentationML timing tree:
    /// tmRoot › mainSeq › click group (par) › with/after group (par) › effect (par).
    static func timingXML(_ anims: [SlideAnimation], ids: [Int: Int], movies: [Int] = []) -> String {
        let valid = anims.filter { ids[$0.shapeID] != nil }
        guard !valid.isEmpty || !movies.isEmpty else { return "" }
        var ctn = 2
        func next() -> Int { ctn += 1; return ctn }

        // Group into clicks, then into sequential sub-groups.
        var clicks: [[[SlideAnimation]]] = []
        for a in valid {
            if a.trigger == .onClick || clicks.isEmpty { clicks.append([[a]]) }
            else if a.trigger == .withPrevious { clicks[clicks.count - 1][clicks[clicks.count - 1].count - 1].append(a) }
            else { clicks[clicks.count - 1].append([a]) }
        }

        var seq = ""
        for click in clicks {
            var groups = ""
            var offset = 0.0
            for group in click {
                var effects = ""
                for a in group { effects += effectXML(a, spid: ids[a.shapeID]!, next: next) }
                groups += "<p:par><p:cTn id=\"\(next())\" fill=\"hold\"><p:stCondLst><p:cond delay=\"\(Int(offset * 1000))\"/></p:stCondLst><p:childTnLst>\(effects)</p:childTnLst></p:cTn></p:par>"
                offset += group.map { $0.delay + max(0.001, $0.duration) }.max() ?? 0
            }
            seq += "<p:par><p:cTn id=\"\(next())\" fill=\"hold\"><p:stCondLst><p:cond delay=\"indefinite\"/></p:stCondLst><p:childTnLst>\(groups)</p:childTnLst></p:cTn></p:par>"
        }
        let built = Set(valid.compactMap { ids[$0.shapeID] }).sorted().map { "<p:bldP spid=\"\($0)\" grpId=\"0\" animBg=\"1\"/>" }.joined()
        let sequence = seq.isEmpty ? "" : "<p:seq concurrent=\"1\" nextAc=\"seek\"><p:cTn id=\"2\" dur=\"indefinite\" nodeType=\"mainSeq\"><p:childTnLst>\(seq)</p:childTnLst></p:cTn>"
            + "<p:prevCondLst><p:cond evt=\"onPrev\" delay=\"0\"><p:tgtEl><p:sldTgt/></p:tgtEl></p:cond></p:prevCondLst>"
            + "<p:nextCondLst><p:cond evt=\"onNext\" delay=\"0\"><p:tgtEl><p:sldTgt/></p:tgtEl></p:cond></p:nextCondLst></p:seq>"
        let videoNodes = movies.map { target in
            "<p:video><p:cMediaNode vol=\"80000\"><p:cTn id=\"\(next())\" fill=\"hold\" display=\"0\"><p:stCondLst><p:cond delay=\"indefinite\"/></p:stCondLst></p:cTn><p:tgtEl><p:spTgt spid=\"\(target)\"/></p:tgtEl></p:cMediaNode></p:video>"
        }.joined()
        let builds = built.isEmpty ? "" : "<p:bldLst>\(built)</p:bldLst>"
        return "<p:timing><p:tnLst><p:par><p:cTn id=\"1\" dur=\"indefinite\" restart=\"never\" nodeType=\"tmRoot\"><p:childTnLst>\(sequence)\(videoNodes)</p:childTnLst></p:cTn></p:par></p:tnLst>\(builds)</p:timing>"
    }

    private static func effectXML(_ a: SlideAnimation, spid: Int, next: () -> Int) -> String {
        let ms = max(1, Int(a.duration * 1000))
        let tgt = "<p:tgtEl><p:spTgt spid=\"\(spid)\"/></p:tgtEl>"
        func bhvr(_ dur: Int, _ extra: String = "", delay: Int = 0) -> String {
            "<p:cBhvr\(extra)><p:cTn id=\"\(next())\" dur=\"\(dur)\" fill=\"hold\"" + (delay > 0 ? "><p:stCondLst><p:cond delay=\"\(delay)\"/></p:stCondLst></p:cTn>" : "/>") + tgt
        }
        func visibility(_ v: String, delay: Int = 0) -> String {
            "<p:set>\(bhvr(1, delay: delay))<p:attrNameLst><p:attrName>style.visibility</p:attrName></p:attrNameLst></p:cBhvr><p:to><p:strVal val=\"\(v)\"/></p:to></p:set>"
        }
        func filter(_ f: String, _ inOut: String) -> String { "<p:animEffect transition=\"\(inOut)\" filter=\"\(f)\">\(bhvr(ms))</p:cBhvr></p:animEffect>" }
        func anim(_ attr: String, _ from: String, _ to: String) -> String {
            "<p:anim calcmode=\"lin\" valueType=\"num\">\(bhvr(ms, " additive=\"base\""))<p:attrNameLst><p:attrName>\(attr)</p:attrName></p:attrNameLst></p:cBhvr>"
                + "<p:tavLst><p:tav tm=\"0\"><p:val><p:strVal val=\"\(from)\"/></p:val></p:tav><p:tav tm=\"100000\"><p:val><p:strVal val=\"\(to)\"/></p:val></p:tav></p:tavLst></p:anim>"
        }
        let away: (String, String) = {
            switch a.direction {
            case .bottom: return ("ppt_y", "1+#ppt_h/2")
            case .top: return ("ppt_y", "0-#ppt_h/2")
            case .left: return ("ppt_x", "0-#ppt_w/2")
            case .right: return ("ppt_x", "1+#ppt_w/2")
            }
        }()
        let home = away.0 == "ppt_y" ? "#ppt_y" : "#ppt_x"
        let wipeDir = ["bottom": "up", "top": "down", "left": "right", "right": "left"][a.direction.rawValue]!
        let hideAtEnd = visibility("hidden", delay: max(1, ms - 1))
        var body: String
        var subtype = 0
        switch a.effect {
        case .appear: body = visibility("visible")
        case .fade: body = visibility("visible") + filter("fade", "in")
        case .flyIn: body = visibility("visible") + anim(away.0, away.1, home); subtype = a.direction.subtype
        case .floatIn: body = visibility("visible") + filter("fade", "in") + anim("ppt_y", "#ppt_y+.1", "#ppt_y")
        case .wipe: body = visibility("visible") + filter("wipe(\(wipeDir))", "in"); subtype = a.direction.subtype
        case .split: body = visibility("visible") + filter("barn(inVertical)", "in"); subtype = 21
        case .zoom: body = visibility("visible") + anim("ppt_w", "0", "#ppt_w") + anim("ppt_h", "0", "#ppt_h"); subtype = 16
        case .wheel: body = visibility("visible") + filter("wheel(1)", "in"); subtype = 1
        case .spin: body = "<p:animRot by=\"21600000\">\(bhvr(ms))<p:attrNameLst><p:attrName>r</p:attrName></p:attrNameLst></p:cBhvr></p:animRot>"
        case .growShrink: body = "<p:animScale>\(bhvr(ms))</p:cBhvr><p:by x=\"150000\" y=\"150000\"/></p:animScale>"
        case .transparency:
            body = "<p:set>\(bhvr(ms))<p:attrNameLst><p:attrName>style.opacity</p:attrName></p:attrNameLst></p:cBhvr><p:to><p:strVal val=\"0.5\"/></p:to></p:set>"
        case .pulse: body = "<p:animScale>\(bhvr(ms / 2, " autoRev=\"1\""))</p:cBhvr><p:by x=\"105000\" y=\"105000\"/></p:animScale>"
        case .disappear: body = visibility("hidden")
        case .fadeOut: body = filter("fade", "out") + hideAtEnd
        case .flyOut: body = anim(away.0, home, away.1) + hideAtEnd; subtype = a.direction.subtype
        case .floatOut: body = filter("fade", "out") + anim("ppt_y", "#ppt_y", "#ppt_y+.1") + hideAtEnd
        case .wipeOut: body = filter("wipe(\(wipeDir))", "out") + hideAtEnd; subtype = a.direction.subtype
        case .splitOut: body = filter("barn(outVertical)", "out") + hideAtEnd; subtype = 37
        case .zoomOut: body = anim("ppt_w", "#ppt_w", "0") + anim("ppt_h", "#ppt_h", "0") + hideAtEnd; subtype = 16
        }
        let cls = a.effect.animClass.rawValue
        return "<p:par><p:cTn id=\"\(next())\" presetID=\"\(a.effect.presetID)\" presetClass=\"\(cls)\" presetSubtype=\"\(subtype)\" fill=\"hold\" grpId=\"0\" nodeType=\"\(a.trigger.rawValue)\">"
            + "<p:stCondLst><p:cond delay=\"\(Int(a.delay * 1000))\"/></p:stCondLst><p:childTnLst>\(body)</p:childTnLst></p:cTn></p:par>"
    }

    private static func solid(_ c: RGB) -> String { "<a:solidFill><a:srgbClr val=\"\(c.hex)\"/></a:solidFill>" }

    private static func xfrm(_ s: SlideShape, tag: String = "a:xfrm") -> String {
        var attrs = ""
        if s.rotation != 0 { attrs += " rot=\"\(Int(s.rotation * 60000))\"" }
        if s.flipH { attrs += " flipH=\"1\"" }
        if s.flipV { attrs += " flipV=\"1\"" }
        return "<\(tag)\(attrs)><a:off x=\"\(DrawingML.emu(s.frame.x))\" y=\"\(DrawingML.emu(s.frame.y))\"/><a:ext cx=\"\(DrawingML.emu(max(0, s.frame.w)))\" cy=\"\(DrawingML.emu(max(0, s.frame.h)))\"/></\(tag)>"
    }

    private static func line(_ s: SlideShape) -> String {
        guard let c = s.line else { return "<a:ln><a:noFill/></a:ln>" }
        return "<a:ln w=\"\(DrawingML.emu(s.lineWidth))\">\(solid(c))</a:ln>"
    }

    static func shapeXML(_ s: SlideShape, id: Int, imageRel: (String) -> String?, movie: (video: String, media: String)? = nil) -> String {
        let name = XMLEscape.text(s.name.isEmpty ? "Shape \(id)" : s.name)
        switch s.kind {
        case .image:
            guard let img = s.imageID, let r = imageRel(img) else { return "" }
            let click = movie == nil ? "" : "<a:hlinkClick r:id=\"\" action=\"ppaction://media\"/>"
            let video = movie.map { refs in
                "<a:videoFile r:link=\"\(refs.video)\"/><p:extLst><p:ext uri=\"{DAA4B4D4-6D71-4841-9C94-3DE7FCFB9230}\"><p14:media xmlns:p14=\"http://schemas.microsoft.com/office/powerpoint/2010/main\" r:embed=\"\(refs.media)\"/></p:ext></p:extLst>"
            } ?? ""
            return "<p:pic><p:nvPicPr><p:cNvPr id=\"\(id)\" name=\"\(name)\">\(click)</p:cNvPr><p:cNvPicPr><a:picLocks noChangeAspect=\"\(s.lockAspect ? 1 : 0)\"/></p:cNvPicPr><p:nvPr>\(video)</p:nvPr></p:nvPicPr>"
                + "<p:blipFill><a:blip r:embed=\"\(r)\"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>"
                + "<p:spPr>\(xfrm(s))<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom>\(s.line != nil ? line(s) : "")</p:spPr></p:pic>"
        case .line:
            return "<p:cxnSp><p:nvCxnSpPr><p:cNvPr id=\"\(id)\" name=\"\(name)\"/><p:cNvCxnSpPr><a:cxnSpLocks noChangeAspect=\"\(s.lockAspect ? 1 : 0)\"/></p:cNvCxnSpPr><p:nvPr/></p:nvCxnSpPr>"
                + "<p:spPr>\(xfrm(s))<a:prstGeom prst=\"line\"><a:avLst/></a:prstGeom>\(line(SlideShape(line: s.line ?? .black, lineWidth: s.lineWidth)))</p:spPr></p:cxnSp>"
        case .table:
            guard let t = s.table else { return "" }
            return tableXML(s, t, id: id, name: name)
        default:
            let prst = s.kind == .text ? "rect" : s.kind.rawValue
            var x = "<p:sp><p:nvSpPr><p:cNvPr id=\"\(id)\" name=\"\(name)\"/><p:cNvSpPr\(s.kind == .text ? " txBox=\"1\"" : "")><a:spLocks noChangeAspect=\"\(s.lockAspect ? 1 : 0)\"/></p:cNvSpPr><p:nvPr/></p:nvSpPr>"
            x += "<p:spPr>\(xfrm(s))<a:prstGeom prst=\"\(prst)\"><a:avLst/></a:prstGeom>"
            x += s.fill.map(solid) ?? "<a:noFill/>"
            x += line(s) + "</p:spPr>"
            x += textBody(s)
            return x + "</p:sp>"
        }
    }

    static func textBody(_ s: SlideShape, tag: String = "p:txBody") -> String {
        let anchor = ["top": "t", "center": "ctr", "bottom": "b"][s.anchor.rawValue]!
        var x = "<\(tag)><a:bodyPr wrap=\"\(s.wrap ? "square" : "none")\" lIns=\"\(DrawingML.emu(s.insets.left))\" tIns=\"\(DrawingML.emu(s.insets.top))\" "
        x += "rIns=\"\(DrawingML.emu(s.insets.right))\" bIns=\"\(DrawingML.emu(s.insets.bottom))\" anchor=\"\(anchor)\" rtlCol=\"0\">"
        x += s.autofitScale < 0.999 ? "<a:normAutofit fontScale=\"\(Int(s.autofitScale * 100000))\"/>" : "<a:noAutofit/>"
        x += "</a:bodyPr><a:lstStyle/>"
        let paras = s.paragraphs.isEmpty ? [Paragraph()] : s.paragraphs
        for p in paras { x += paragraphXML(p) }
        return x + "</\(tag)>"
    }

    private static func runProps(_ c: CharProps, tag: String = "a:rPr") -> String {
        var a = " lang=\"ko-KR\" altLang=\"en-US\" sz=\"\(Int((c.size * 100).rounded()))\""
        if c.bold { a += " b=\"1\"" }
        if c.italic { a += " i=\"1\"" }
        if c.underline != .none { a += " u=\"\(c.underline == .double ? "dbl" : "sng")\"" }
        if c.strike { a += " strike=\"sngStrike\"" }
        if c.verticalAlign != .baseline { a += " baseline=\"\(c.verticalAlign == .superscript ? 30000 : -25000)\"" }
        if c.spacing != 0 { a += " spc=\"\(Int(c.spacing * 100))\"" }
        let latin = XMLEscape.text(c.fontName), ea = XMLEscape.text(c.eastAsianFontName ?? c.fontName)
        return "<\(tag)\(a) dirty=\"0\">\(solid(c.color))\(c.highlight.map { "<a:highlight><a:srgbClr val=\"\($0.hex)\"/></a:highlight>" } ?? "")<a:latin typeface=\"\(latin)\"/><a:ea typeface=\"\(ea)\"/></\(tag)>"
    }

    private static func paragraphXML(_ p: Paragraph) -> String {
        let algn = [Alignment.left: "l", .center: "ctr", .right: "r", .justify: "just", .distribute: "dist"][p.props.alignment]!
        var pPr = "<a:pPr algn=\"\(algn)\" marL=\"\(DrawingML.emu(p.props.indentLeft))\" indent=\"\(DrawingML.emu(p.props.firstLine))\">"
        switch p.props.lineSpacing {
        case .multiple(let m): pPr += "<a:lnSpc><a:spcPct val=\"\(Int(m * 100000))\"/></a:lnSpc>"
        case .percentOfSize(let pct): pPr += "<a:lnSpc><a:spcPct val=\"\(Int(pct / 1.2 * 1000))\"/></a:lnSpc>"
        case .exact(let v), .atLeast(let v): pPr += "<a:lnSpc><a:spcPts val=\"\(Int(v * 100))\"/></a:lnSpc>"
        }
        if p.props.spaceBefore > 0 { pPr += "<a:spcBef><a:spcPts val=\"\(Int(p.props.spaceBefore * 100))\"/></a:spcBef>" }
        if p.props.spaceAfter > 0 { pPr += "<a:spcAft><a:spcPts val=\"\(Int(p.props.spaceAfter * 100))\"/></a:spcAft>" }
        if let b = p.props.listLabel {
            pPr += b == "#" ? "<a:buFont typeface=\"+mj-lt\"/><a:buAutoNum type=\"arabicPeriod\"/>" : "<a:buFont typeface=\"Arial\"/><a:buChar char=\"\(XMLEscape.text(b))\"/>"
        } else { pPr += "<a:buNone/>" }
        pPr += "</a:pPr>"
        var x = "<a:p>" + pPr
        for i in p.inlines {
            switch i {
            case .text(let t, let c):
                for (n, piece) in t.components(separatedBy: CharacterSet(charactersIn: "\n\u{2028}")).enumerated() {
                    if n > 0 { x += "<a:br>\(runProps(c))</a:br>" }
                    if !piece.isEmpty { x += "<a:r>\(runProps(c))<a:t>\(XMLEscape.text(piece))</a:t></a:r>" }
                }
            case .tab(let c): x += "<a:r>\(runProps(c))<a:t>\t</a:t></a:r>"
            case .lineBreak(let c): x += "<a:br>\(runProps(c))</a:br>"
            default: break
            }
        }
        return x + runProps(p.markProps, tag: "a:endParaRPr") + "</a:p>"
    }

    private static func tableXML(_ s: SlideShape, _ t: Table, id: Int, name: String) -> String {
        var x = "<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id=\"\(id)\" name=\"\(name)\"/><p:cNvGraphicFramePr><a:graphicFrameLocks noGrp=\"1\" noChangeAspect=\"\(s.lockAspect ? 1 : 0)\"/></p:cNvGraphicFramePr><p:nvPr/></p:nvGraphicFramePr>"
        x += xfrm(s,tag:"p:xfrm")
        x += "<a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/table\"><a:tbl><a:tblPr firstRow=\"1\" bandRow=\"1\"/><a:tblGrid>"
        let columns=t.columnWidths.isEmpty ? Array(repeating:s.frame.w/Double(max(1,t.columnCount)),count:max(1,t.columnCount)) : t.columnWidths
        for w in columns { x += "<a:gridCol w=\"\(DrawingML.emu(w*s.frame.w/max(1,columns.reduce(0,+))))\"/>" }
        x += "</a:tblGrid>"
        let border = "<a:lnL w=\"12700\">\(solid(.black))</a:lnL><a:lnR w=\"12700\">\(solid(.black))</a:lnR><a:lnT w=\"12700\">\(solid(.black))</a:lnT><a:lnB w=\"12700\">\(solid(.black))</a:lnB>"
        let heights=t.rows.indices.map { $0<s.tableRowHeights.count ? s.tableRowHeights[$0] : s.frame.h/Double(max(1,t.rows.count)) }
        for (r, row) in t.rows.enumerated() {
            let h=heights[r]*s.frame.h/max(1,heights.reduce(0,+))
            x += "<a:tr h=\"\(DrawingML.emu(h))\">"
            for (c, cell) in row.enumerated() {
                var attrs = ""
                if cell.isMergedAway {
                    // Covered by a span to the left or above.
                    let left = c > 0 && row[..<c].contains { !$0.isMergedAway && $0.colSpan > 1 }
                    attrs = left ? " hMerge=\"1\"" : " vMerge=\"1\""
                } else {
                    if cell.colSpan > 1 { attrs += " gridSpan=\"\(cell.colSpan)\"" }
                    if cell.rowSpan > 1 { attrs += " rowSpan=\"\(cell.rowSpan)\"" }
                }
                var shape = SlideShape()
                shape.paragraphs = cell.blocks.compactMap { if case .paragraph(let p) = $0 { return p } else { return nil } }
                shape.anchor = cell.verticalAlign
                let body = textBody(shape, tag: "a:txBody").replacingOccurrences(of: "<a:noAutofit/>", with: "")
                let anchor = ["top": "t", "center": "ctr", "bottom": "b"][cell.verticalAlign.rawValue]!
                x += "<a:tc\(attrs)>\(body)<a:tcPr anchor=\"\(anchor)\">\(border)\(cell.background.map(solid) ?? "")</a:tcPr></a:tc>"
            }
            x += "</a:tr>"
        }
        return x + "</a:tbl></a:graphicData></a:graphic></p:graphicFrame>"
    }

    static let theme = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?><a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="HanX"><a:themeElements>\
    <a:clrScheme name="HanX"><a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1><a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1>\
    <a:dk2><a:srgbClr val="24364B"/></a:dk2><a:lt2><a:srgbClr val="F0F4F8"/></a:lt2><a:accent1><a:srgbClr val="2463A6"/></a:accent1>\
    <a:accent2><a:srgbClr val="B77A37"/></a:accent2><a:accent3><a:srgbClr val="6D8193"/></a:accent3><a:accent4><a:srgbClr val="C3A243"/></a:accent4>\
    <a:accent5><a:srgbClr val="368A9B"/></a:accent5><a:accent6><a:srgbClr val="588258"/></a:accent6><a:hlink><a:srgbClr val="245C99"/></a:hlink>\
    <a:folHlink><a:srgbClr val="725B95"/></a:folHlink></a:clrScheme>\
    <a:fontScheme name="HanX"><a:majorFont><a:latin typeface="Apple SD Gothic Neo"/><a:ea typeface="Apple SD Gothic Neo"/><a:cs typeface=""/></a:majorFont>\
    <a:minorFont><a:latin typeface="Apple SD Gothic Neo"/><a:ea typeface="Apple SD Gothic Neo"/><a:cs typeface=""/></a:minorFont></a:fontScheme>\
    <a:fmtScheme name="HanX"><a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill>\
    <a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst><a:lnStyleLst><a:ln w="6350"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln>\
    <a:ln w="12700"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="19050"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln></a:lnStyleLst>\
    <a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst>\
    <a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill>\
    <a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst></a:fmtScheme></a:themeElements><a:objectDefaults/><a:extraClrSchemeLst/></a:theme>
    """
}

enum SlidesIO {
    static func load(url: URL) throws -> Presentation {
        let data = try Data(contentsOf: url)
        guard ZipReader.isZip(data) else { throw FormatError.unsupported("pptx 형식만 열 수 있습니다") }
        let p = try PPTXReader(zip: ZipReader(data: data)).read()
        return p
    }
}
