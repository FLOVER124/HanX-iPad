import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Compound File Binary (OLE2 structured storage), the container HWP 5.0
/// shares with legacy .doc. Reader handles v3/v4, DIFAT and the mini stream;
/// writer emits v3 (512-byte sectors) with a proper mini stream.
final class CFBReader {
    private struct Entry {
        var name: String
        var type: UInt8          // 1 storage, 2 stream, 5 root
        var left: UInt32, right: UInt32, child: UInt32
        var start: UInt32
        var size: UInt64
    }

    private static let endOfChain: UInt32 = 0xFFFF_FFFE
    private static let noStream: UInt32 = 0xFFFF_FFFF

    private let bytes: [UInt8]
    private let sectorSize: Int
    private let miniSectorSize: Int
    private let miniCutoff: UInt32
    private var fat: [UInt32] = []
    private var miniFat: [UInt32] = []
    private var entries: [Entry] = []
    private var miniStream: [UInt8] = []
    private(set) var paths: [String: Int] = [:]

    static func isCFB(_ data: Data) -> Bool {
        data.count >= 8 && [UInt8](data.prefix(8)) == [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
    }

    init(data: Data) throws {
        bytes = [UInt8](data)
        guard CFBReader.isCFB(data), bytes.count >= 512 else { throw FormatError.invalid("CFB 시그니처 없음") }
        sectorSize = 1 << Int(ByteReader.u16(bytes, 0x1E))
        miniSectorSize = 1 << Int(ByteReader.u16(bytes, 0x20))
        guard sectorSize == 512 || sectorSize == 4096 else { throw FormatError.invalid("CFB 섹터 크기 \(sectorSize)") }
        miniCutoff = ByteReader.u32(bytes, 0x38)
        let numFat = Int(ByteReader.u32(bytes, 0x2C))
        let firstDir = ByteReader.u32(bytes, 0x30)
        let firstMiniFat = ByteReader.u32(bytes, 0x3C)
        var difatNext = ByteReader.u32(bytes, 0x44)

        var fatSectors: [UInt32] = []
        for i in 0..<109 {
            let s = ByteReader.u32(bytes, 0x4C + i * 4)
            if s < 0xFFFF_FFFA { fatSectors.append(s) }
        }
        var guardCount = 0
        while difatNext < 0xFFFF_FFFA && fatSectors.count < numFat && guardCount < 100_000 {
            let off = offset(of: difatNext)
            let perSector = sectorSize / 4 - 1
            for i in 0..<perSector {
                let s = ByteReader.u32(bytes, off + i * 4)
                if s < 0xFFFF_FFFA { fatSectors.append(s) }
            }
            difatNext = ByteReader.u32(bytes, off + perSector * 4)
            guardCount += 1
        }
        for s in fatSectors {
            let off = offset(of: s)
            for i in 0..<(sectorSize / 4) { fat.append(ByteReader.u32(bytes, off + i * 4)) }
        }

        let dirBytes = readChain(start: firstDir, fat: fat, unit: sectorSize, source: nil)
        var i = 0
        while i + 128 <= dirBytes.count {
            var r = ByteReader(dirBytes, at: i)
            let nameUnits = (0..<32).map { _ in r.u16() }
            let nameLen = Int(r.u16())
            let type = r.u8()
            _ = r.u8()
            let left = r.u32(), right = r.u32(), child = r.u32()
            r.skip(16 + 4 + 16)
            let start = r.u32()
            let size = r.u64()
            let n = max(0, min(32, nameLen / 2 - 1))
            entries.append(Entry(name: String(decoding: nameUnits.prefix(n), as: UTF16.self),
                                 type: type, left: left, right: right, child: child, start: start,
                                 size: sectorSize == 512 ? size & 0xFFFF_FFFF : size))
            i += 128
        }
        guard let root = entries.first, root.type == 5 else { throw FormatError.invalid("CFB 루트 엔트리 없음") }

        miniFat = bytesToU32(readChain(start: firstMiniFat, fat: fat, unit: sectorSize, source: nil))
        miniStream = readChain(start: root.start, fat: fat, unit: sectorSize, source: nil)
        if miniStream.count > Int(root.size) { miniStream = Array(miniStream.prefix(Int(root.size))) }

        var visited = Set<UInt32>()
        walk(root.child, prefix: "", visited: &visited)
    }

    var streamNames: [String] { paths.keys.sorted() }

    func stream(_ path: String) -> [UInt8]? {
        guard let idx = paths[path] else { return nil }
        let e = entries[idx]
        guard e.type == 2 else { return nil }
        let out: [UInt8]
        if e.size < UInt64(miniCutoff) {
            out = readChain(start: e.start, fat: miniFat, unit: miniSectorSize, source: miniStream)
        } else {
            out = readChain(start: e.start, fat: fat, unit: sectorSize, source: nil)
        }
        return Array(out.prefix(Int(e.size)))
    }

    private func walk(_ idx: UInt32, prefix: String, visited: inout Set<UInt32>) {
        guard idx != CFBReader.noStream, Int(idx) < entries.count, !visited.contains(idx) else { return }
        visited.insert(idx)
        let e = entries[Int(idx)]
        walk(e.left, prefix: prefix, visited: &visited)
        let path = prefix.isEmpty ? e.name : prefix + "/" + e.name
        paths[path] = Int(idx)
        if e.type == 1 { walk(e.child, prefix: path, visited: &visited) }
        walk(e.right, prefix: prefix, visited: &visited)
    }

    private func offset(of sector: UInt32) -> Int { (Int(sector) + 1) * sectorSize }

    private func readChain(start: UInt32, fat: [UInt32], unit: Int, source: [UInt8]?) -> [UInt8] {
        var out = [UInt8]()
        var s = start
        var seen = 0
        while s < 0xFFFF_FFFA && Int(s) < fat.count && seen <= fat.count {
            let off = source == nil ? offset(of: s) : Int(s) * unit
            let src = source ?? bytes
            if off >= src.count { break }
            out.append(contentsOf: src[off..<min(off + unit, src.count)])
            s = fat[Int(s)]
            seen += 1
        }
        return out
    }

    private func bytesToU32(_ b: [UInt8]) -> [UInt32] {
        stride(from: 0, to: b.count - 3, by: 4).map { ByteReader.u32(b, $0) }
    }
}

final class CFBWriter {
    private var streams: [(path: [String], data: [UInt8])] = []

    func add(_ path: String, _ data: [UInt8]) {
        streams.append((path.split(separator: "/").map(String.init), data))
    }

    private final class Node {
        var name: String
        var isStorage: Bool
        var data: [UInt8] = []
        var children: [Node] = []
        var index = 0
        var start: UInt32 = 0xFFFF_FFFE
        var left: UInt32 = 0xFFFF_FFFF, right: UInt32 = 0xFFFF_FFFF, child: UInt32 = 0xFFFF_FFFF
        init(_ name: String, storage: Bool) { self.name = name; isStorage = storage }
    }

    private static func compare(_ a: String, _ b: String) -> Bool {
        let la = a.utf16.count, lb = b.utf16.count
        if la != lb { return la < lb }
        return Array(a.uppercased().utf16).lexicographicallyPrecedes(Array(b.uppercased().utf16))
    }

    func build() -> [UInt8] {
        let ss = 512, mss = 64, cutoff = 4096
        let free: UInt32 = 0xFFFF_FFFF, eoc: UInt32 = 0xFFFF_FFFE, fatSect: UInt32 = 0xFFFF_FFFD, difSect: UInt32 = 0xFFFF_FFFC

        let root = Node("Root Entry", storage: true)
        for s in streams {
            var cur = root
            for (i, comp) in s.path.enumerated() {
                let last = i == s.path.count - 1
                if let ex = cur.children.first(where: { $0.name == comp }) { cur = ex; if last { ex.data = s.data }; continue }
                let n = Node(comp, storage: !last)
                if last { n.data = s.data }
                cur.children.append(n)
                cur = n
            }
        }
        var all: [Node] = []
        func number(_ n: Node) { n.index = all.count; all.append(n); n.children.forEach(number) }
        number(root)

        func tree(_ nodes: [Node]) -> UInt32 {
            guard !nodes.isEmpty else { return free }
            let mid = nodes.count / 2
            let n = nodes[mid]
            n.left = tree(Array(nodes[..<mid]))
            n.right = tree(Array(nodes[(mid + 1)...]))
            return UInt32(n.index)
        }
        for n in all where n.isStorage {
            n.child = tree(n.children.sorted { CFBWriter.compare($0.name, $1.name) })
        }

        // Mini stream for small streams.
        var mini = [UInt8]()
        var miniFat = [UInt32]()
        var big: [Node] = []
        for n in all where !n.isStorage {
            if n.data.isEmpty { n.start = eoc; continue }
            if n.data.count < cutoff {
                let first = miniFat.count
                let count = (n.data.count + mss - 1) / mss
                for k in 0..<count { miniFat.append(k == count - 1 ? eoc : UInt32(first + k + 1)) }
                n.start = UInt32(first)
                mini.append(contentsOf: n.data)
                mini.append(contentsOf: [UInt8](repeating: 0, count: count * mss - n.data.count))
            } else {
                big.append(n)
            }
        }

        func sectors(_ bytes: Int) -> Int { (bytes + ss - 1) / ss }
        let dirSectors = sectors(all.count * 128)
        let miniFatSectors = sectors(miniFat.count * 4)
        let miniSectors = sectors(mini.count)
        let dataSectors = big.reduce(0) { $0 + sectors($1.data.count) } + miniSectors + miniFatSectors + dirSectors

        var fatCount = 1, difatCount = 0
        while true {
            let needDifat = max(0, fatCount - 109)
            difatCount = needDifat == 0 ? 0 : (needDifat + 126) / 127
            let total = dataSectors + fatCount + difatCount
            let need = (total + 127) / 128
            if need <= fatCount { break }
            fatCount = need
        }

        var fat = [UInt32]()
        func chain(_ count: Int) -> UInt32 {
            guard count > 0 else { return eoc }
            let first = fat.count
            for k in 0..<count { fat.append(k == count - 1 ? eoc : UInt32(first + k + 1)) }
            return UInt32(first)
        }
        var body = [UInt8]()
        func emit(_ d: [UInt8]) {
            body.append(contentsOf: d)
            let rem = d.count % ss
            if rem != 0 { body.append(contentsOf: [UInt8](repeating: 0, count: ss - rem)) }
        }
        for n in big { n.start = chain(sectors(n.data.count)); emit(n.data) }
        root.start = miniSectors > 0 ? chain(miniSectors) : eoc
        emit(mini)
        let miniFatStart = miniFatSectors > 0 ? chain(miniFatSectors) : eoc
        var mfw = ByteWriter()
        miniFat.forEach { mfw.u32($0) }
        emit(mfw.data)
        let dirStart = chain(dirSectors)

        var dw = ByteWriter()
        for n in all {
            let start = dw.data.count
            let nameUnits = Array(n.name.utf16.prefix(31))
            nameUnits.forEach { dw.u16($0) }
            dw.pad(to: start + 64)
            dw.u16(UInt16((nameUnits.count + 1) * 2))
            dw.u8(n === root ? 5 : (n.isStorage ? 1 : 2))
            dw.u8(1) // black
            dw.u32(n.left); dw.u32(n.right); dw.u32(n.child)
            dw.zeros(16 + 4 + 16)
            if n === root { dw.u32(root.start); dw.u64(UInt64(mini.count)) }
            else if n.isStorage { dw.u32(0); dw.u64(0) }
            else { dw.u32(n.start); dw.u64(UInt64(n.data.count)) }
        }
        dw.pad(to: dirSectors * ss)
        // Unused directory slots must be marked empty with no siblings.
        var d = dw.data
        for slot in all.count..<(dirSectors * ss / 128) {
            let o = slot * 128
            for k in 0..<12 { d[o + 0x44 + k] = 0xFF }
        }
        emit(d)

        let fatStart = fat.count
        for _ in 0..<fatCount { fat.append(fatSect) }
        let difatStart = fat.count
        for _ in 0..<difatCount { fat.append(difSect) }
        while fat.count < fatCount * 128 { fat.append(free) }

        var fw = ByteWriter()
        fat.forEach { fw.u32($0) }
        body.append(contentsOf: fw.data)
        var dfw = ByteWriter()
        if difatCount > 0 {
            var k = 109
            for s in 0..<difatCount {
                for _ in 0..<127 {
                    dfw.u32(k < fatCount ? UInt32(fatStart + k) : free)
                    k += 1
                }
                dfw.u32(s == difatCount - 1 ? eoc : UInt32(difatStart + s + 1))
            }
        }
        body.append(contentsOf: dfw.data)

        var h = ByteWriter()
        h.bytes([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
        h.zeros(16)
        h.u16(0x3E); h.u16(3); h.u16(0xFFFE); h.u16(9); h.u16(6)
        h.zeros(6)
        h.u32(0)                      // dir sectors (v3: 0)
        h.u32(UInt32(fatCount))
        h.u32(dirStart)
        h.u32(0)
        h.u32(UInt32(cutoff))
        h.u32(miniFatStart)
        h.u32(UInt32(miniFatSectors))
        h.u32(difatCount > 0 ? UInt32(difatStart) : eoc)
        h.u32(UInt32(difatCount))
        for k in 0..<109 { h.u32(k < fatCount ? UInt32(fatStart + k) : free) }
        return h.data + body
    }
}
