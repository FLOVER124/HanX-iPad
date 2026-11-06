import UIKit
import CoreText

/// Maps document font names to installed faces, like the macOS FontResolver:
/// Hancom faces (함초롬바탕, 한컴돋움 …) and Office faces fall back by design
/// class (serif → 명조, sans → 고딕) when the face is not on the iPad.
/// Fonts the user adds with "글꼴 추가…" are copied into the app container
/// and registered for this process at every launch.
final class FontResolver {
    static let shared = FontResolver()

    struct Resolved { let font: UIFont; let syntheticBold: Bool; let syntheticItalic: Bool }

    private var cache: [String: Resolved] = [:]
    private var familyIndex: [String: String] = [:]   // normalised family/display name → family name
    private var nameIndex: [String: String] = [:]     // localised names from 'name' tables → PostScript name
    private let lock = NSLock()

    static let substitutes: [String: [String]] = [
        "함초롬바탕": ["한컴바탕", "HY신명조", "바탕", "AppleMyungjo", "Nanum Myeongjo"],
        "함초롬돋움": ["한컴돋움", "돋움", "맑은 고딕", "Apple SD Gothic Neo"],
        "한컴바탕": ["HY신명조", "바탕", "AppleMyungjo", "Nanum Myeongjo"],
        "한컴돋움": ["돋움", "맑은 고딕", "Apple SD Gothic Neo"],
        "바탕": ["Batang", "한컴바탕", "AppleMyungjo", "Nanum Myeongjo"],
        "바탕체": ["BatangChe", "Batang", "AppleMyungjo"],
        "돋움": ["Dotum", "한컴돋움", "Apple SD Gothic Neo"],
        "돋움체": ["DotumChe", "Dotum", "Apple SD Gothic Neo"],
        "굴림": ["Gulim", "돋움", "Apple SD Gothic Neo"],
        "굴림체": ["GulimChe", "Gulim", "Apple SD Gothic Neo"],
        "궁서": ["Gungsuh", "HY궁서B", "AppleMyungjo"],
        "맑은 고딕": ["Malgun Gothic", "Apple SD Gothic Neo"],
        "나눔고딕": ["NanumGothic", "Nanum Gothic", "Apple SD Gothic Neo"],
        "나눔명조": ["NanumMyeongjo", "Nanum Myeongjo", "AppleMyungjo"],
        "새굴림": ["Gulim", "Apple SD Gothic Neo"],
        "휴먼명조": ["HY신명조", "한컴바탕", "AppleMyungjo"],
        "신명조": ["HY신명조", "한컴바탕", "AppleMyungjo"],
        "중고딕": ["HY중고딕", "한컴돋움", "Apple SD Gothic Neo"],
        "견고딕": ["HY견고딕", "Apple SD Gothic Neo"],
        "Calibri": ["Helvetica Neue", "Arial"],
        "Cambria": ["Georgia", "Times New Roman"],
        "Segoe UI": ["Helvetica Neue"],
    ]

    /// Families offered first in font menus; the rest follow alphabetically.
    static let preferredFamilies = ["Apple SD Gothic Neo", "AppleMyungjo", "Arial", "Helvetica Neue", "Times New Roman", "Georgia"]

    private static func key(_ name: String) -> String {
        name.lowercased().filter { !$0.isWhitespace && $0 != "-" && $0 != "_" }
    }

    private init() { rebuildIndex() }

    private func rebuildIndex() {
        familyIndex = [:]
        for family in UIFont.familyNames { familyIndex[FontResolver.key(family)] = family }
    }

    var allFamilies: [String] {
        let installed = UIFont.familyNames.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let preferred = FontResolver.preferredFamilies.filter { installed.contains($0) }
        return preferred + installed.filter { !preferred.contains($0) }
    }

    // MARK: User fonts

    private var fontsFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Fonts", isDirectory: true)
    }

    func registerImportedFonts() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: fontsFolder, includingPropertiesForKeys: nil)) ?? []
        for url in urls { register(url) }
        rebuildIndex()
    }

    /// Copies font files into the container; returns the family names added.
    func importFonts(_ urls: [URL]) -> [String] {
        try? FileManager.default.createDirectory(at: fontsFolder, withIntermediateDirectories: true)
        var added: [String] = []
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor], !descriptors.isEmpty else { continue }
            let target = fontsFolder.appendingPathComponent(url.lastPathComponent)
            if !FileManager.default.fileExists(atPath: target.path) {
                do { try FileManager.default.copyItem(at: url, to: target) } catch { continue }
            }
            register(target)
            for d in descriptors {
                if let family = CTFontDescriptorCopyAttribute(d, kCTFontFamilyNameAttribute) as? String, !added.contains(family) { added.append(family) }
            }
        }
        lock.lock(); cache = [:]; lock.unlock()
        rebuildIndex()
        return added
    }

    private func register(_ url: URL) {
        var error: Unmanaged<CFError>?
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        guard let descs = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] else { return }
        for d in descs {
            let font = CTFontCreateWithFontDescriptor(d, 12, nil)
            let ps = CTFontCopyPostScriptName(font) as String
            for n in FontResolver.names(font) { nameIndex[FontResolver.key(n)] = ps }
        }
    }

    /// Family (1), full (4) and typographic family (16) names in every language.
    private static func names(_ font: CTFont) -> [String] {
        guard let table = CTFontCopyTable(font, CTFontTableTag(kCTFontTableName), []) as Data? else { return [] }
        let b = [UInt8](table)
        func u16(_ o: Int) -> Int { o + 1 < b.count ? Int(b[o]) << 8 | Int(b[o + 1]) : 0 }
        let count = u16(2), strings = u16(4)
        var out: [String] = []
        for i in 0..<count {
            let r = 6 + i * 12
            let platform = u16(r), nameID = u16(r + 6), len = u16(r + 8), off = u16(r + 10)
            guard [1, 4, 16].contains(nameID), platform == 0 || platform == 3 else { continue }
            let start = strings + off
            guard start + len <= b.count, len > 1 else { continue }
            let raw = Array(b[start..<(start + len)])
            let units = stride(from: 0, to: raw.count - 1, by: 2).map { UInt16(raw[$0]) << 8 | UInt16(raw[$0 + 1]) }
            out.append(String(decoding: units, as: UTF16.self))
        }
        return out
    }

    // MARK: Resolution

    func font(name: String, size: Double, bold: Bool, italic: Bool) -> Resolved {
        let cacheKey = "\(name)|\(size)|\(bold)|\(italic)"
        lock.lock()
        if let r = cache[cacheKey] { lock.unlock(); return r }
        lock.unlock()
        let size = CGFloat(max(1, min(1600, size.isFinite ? size : 10)))
        var base = lookup(name, size: size)
        if base == nil {
            for alt in FontResolver.substitutes[name] ?? [] { if let f = lookup(alt, size: size) { base = f; break } }
        }
        var font = base ?? fallback(for: name, size: size)
        var syntheticBold = false, syntheticItalic = false
        var traits = font.fontDescriptor.symbolicTraits
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        if traits != font.fontDescriptor.symbolicTraits {
            if let d = font.fontDescriptor.withSymbolicTraits(traits) {
                font = UIFont(descriptor: d, size: size)
            } else if bold, let d = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.traitBold)) {
                font = UIFont(descriptor: d, size: size)
                syntheticItalic = italic
            } else {
                syntheticBold = bold
                syntheticItalic = italic
            }
        }
        let actual = font.fontDescriptor.symbolicTraits
        if bold && !actual.contains(.traitBold) { syntheticBold = true }
        if italic && !actual.contains(.traitItalic) { syntheticItalic = true }
        let r = Resolved(font: font, syntheticBold: syntheticBold, syntheticItalic: syntheticItalic)
        lock.lock(); cache[cacheKey] = r; lock.unlock()
        return r
    }

    private func lookup(_ name: String, size: CGFloat) -> UIFont? {
        let k = FontResolver.key(name)
        if let ps = nameIndex[k], let f = UIFont(name: ps, size: size) { return f }
        if let family = familyIndex[k] {
            let names = UIFont.fontNames(forFamilyName: family)
            // Prefer the upright regular face of the family.
            let regular = names.first { n in
                let l = n.lowercased()
                return l.hasSuffix("-regular") || l.hasSuffix("regular") || !(l.contains("bold") || l.contains("italic") || l.contains("light") || l.contains("thin") || l.contains("medium") || l.contains("semibold") || l.contains("heavy") || l.contains("black") || l.contains("oblique") || l.contains("ultra"))
            } ?? names.first
            if let regular, let f = UIFont(name: regular, size: size) { return f }
        }
        if let f = UIFont(name: name, size: size) { return f }
        // Localised display or family names (e.g. "애플 SD 산돌고딕 Neo").
        for attribute in [kCTFontDisplayNameAttribute, kCTFontFamilyNameAttribute] {
            let desc = CTFontDescriptorCreateWithAttributes([attribute: name] as CFDictionary)
            if let match = (CTFontDescriptorCreateMatchingFontDescriptors(desc, nil) as? [CTFontDescriptor])?.first {
                return CTFontCreateWithFontDescriptor(match, size, nil) as UIFont
            }
        }
        return nil
    }

    static func isSerif(_ name: String) -> Bool {
        let n = name.lowercased()
        let serif = ["바탕", "명조", "batang", "myungjo", "myeongjo", "serif", "times", "궁서", "신명", "georgia", "cambria", "garamond", "book", "바른바탕"]
        let sans = ["돋움", "고딕", "굴림", "dotum", "gulim", "gothic", "sans", "맑은", "arial", "calibri", "helvetica", "segoe", "나눔고딕"]
        if sans.contains(where: n.contains) { return false }
        return serif.contains(where: n.contains)
    }

    private func fallback(for name: String, size: CGFloat) -> UIFont {
        let candidates = FontResolver.isSerif(name)
            ? ["AppleMyungjo", "Nanum Myeongjo", "NanumMyeongjo", "Times New Roman"]
            : ["Apple SD Gothic Neo", "Nanum Gothic", "Helvetica Neue"]
        for c in candidates { if let f = lookup(c, size: size) { return f } }
        return UIFont.systemFont(ofSize: size)
    }
}

extension Character {
    /// Hangul, CJK ideographs, kana and CJK symbols use the East-Asian face.
    var isEastAsian: Bool {
        guard let v = unicodeScalars.first?.value else { return false }
        switch v {
        case 0x1100...0x11FF, 0x3000...0x303F, 0x3040...0x30FF, 0x3130...0x318F, 0x3200...0x32FF,
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA960...0xA97F, 0xAC00...0xD7AF, 0xD7B0...0xD7FF,
             0xF900...0xFAFF, 0xFF00...0xFFEF:
            return true
        default: return false
        }
    }
}
