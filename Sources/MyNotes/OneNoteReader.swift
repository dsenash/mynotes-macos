import Foundation

// Чтение родных файлов OneNote (.one) — формат MS-ONESTORE.
// Файл — это хранилище «пространств объектов»: одно для раздела и по одному на каждую страницу.
// Каждое пространство содержит ревизии (историю правок), а ревизия — набор объектов со свойствами.
// Читатель берёт актуальную ревизию каждой страницы и превращает объекты в простую модель
// (абзацы с форматированием, картинки, файлы, таблицы), не зависящую от AppKit.

// MARK: - Модель

struct ONRun {
    var text: String
    var bold = false
    var italic = false
    var underline = false
    var strike = false
    var superscript = false
    var isSubscript = false
    var fontName: String?
    var sizeHalfPoints: Int?
    var color: UInt32?        // 0xRRGGBB; nil — цвет по умолчанию
    var highlight: UInt32?    // 0xRRGGBB; nil — без выделения
    var link: String?
}

enum ONListKind {
    case bullet
    case numbered
}

enum ONBlock {
    case paragraph(level: Int, style: String, list: ONListKind?, runs: [ONRun])
    case image(data: Data, ext: String, alt: String)
    case file(name: String, ext: String, data: Data)
    case table(rows: [[String]])
}

struct ONPage {
    var title: String
    var created: Date?
    var modified: Date?
    var level: Int
    /// Строки из области заголовка под самим названием (обычно дата и время).
    var headerLines: [String]
    var blocks: [ONBlock]
}

struct ONSection {
    var pages: [ONPage]
}

enum OneNoteError: LocalizedError {
    case notOneNote
    case truncated
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .notOneNote: return "Это не файл раздела OneNote (.one)."
        case .truncated: return "Файл повреждён или обрезан."
        case .unsupported(let s): return "Формат файла не поддерживается: \(s)"
        }
    }
}

// MARK: - Внутренние структуры

private struct OID: Hashable {
    var guid: String   // 16 байт в hex, пустая строка — не разрешено
    var n: UInt32
}

private struct Prop {
    var id: UInt32       // 26 бит
    var type: UInt32     // 5 бит
    var int: UInt64 = 0
    var data: Data = Data()
    var oids: [OID] = []
}

private final class Obj {
    let id: OID
    let jcid: UInt32
    var props: [Prop]
    var file: (guid: String, ext: String)?

    init(id: OID, jcid: UInt32, props: [Prop]) {
        self.id = id
        self.jcid = jcid
        self.props = props
    }

    func prop(_ pid: UInt32) -> Prop? {
        for p in props where p.id == pid { return p }
        return nil
    }

    func oidList(_ pid: UInt32) -> [OID] { prop(pid)?.oids ?? [] }
}

private final class Revision {
    var rid: OID
    var dep: OID
    var objs: [OID: Obj] = [:]
    var order: [OID] = []
    var gid: [Int: String] = [:]

    init(rid: OID, dep: OID) {
        self.rid = rid
        self.dep = dep
    }

    func set(_ o: Obj) {
        if objs[o.id] == nil { order.append(o.id) }
        objs[o.id] = o
    }
}

private final class Space {
    let id: OID
    var revisions: [Revision] = []
    init(id: OID) { self.id = id }
}

// MARK: - Идентификаторы свойств и типов объектов

private enum PID {
    static let childLevel: UInt32 = 0x1c03
    static let bold: UInt32 = 0x1c04
    static let italic: UInt32 = 0x1c05
    static let underline: UInt32 = 0x1c06
    static let strike: UInt32 = 0x1c07
    static let superscript: UInt32 = 0x1c08
    static let subscripted: UInt32 = 0x1c09
    static let fontName: UInt32 = 0x1c0a
    static let fontSize: UInt32 = 0x1c0b
    static let fontColor: UInt32 = 0x1c0c
    static let highlight: UInt32 = 0x1c0d
    static let contentChildren: UInt32 = 0x1c1f
    static let elementChildren: UInt32 = 0x1c20
    static let richTextUnicode: UInt32 = 0x1c22
    static let created: UInt32 = 0x1c65
    static let langID: UInt32 = 0x1cfe
    static let cachedTitle: UInt32 = 0x1cf3
    static let pageLevel: UInt32 = 0x1dff
    static let osidPage: UInt32 = 0x1d63
    static let modified: UInt32 = 0x1d77
    static let textRunIndex: UInt32 = 0x1e12
    static let textRunFormatting: UInt32 = 0x1e13
    static let pictureContainer: UInt32 = 0x1c3f
    static let paragraphStyle: UInt32 = 0x342c
    static let paragraphStyleID: UInt32 = 0x345a
    static let textAscii: UInt32 = 0x3498
}

private enum JC {
    static let section: UInt32 = 0x60007
    static let pageSeries: UInt32 = 0x60008
    static let page: UInt32 = 0x6000b
    static let outline: UInt32 = 0x6000c
    static let outlineElement: UInt32 = 0x6000d
    static let richText: UInt32 = 0x6000e
    static let image: UInt32 = 0x60011
    static let numberList: UInt32 = 0x60012
    static let table: UInt32 = 0x60022
    static let tableRow: UInt32 = 0x60023
    static let tableCell: UInt32 = 0x60024
    static let title: UInt32 = 0x6002c
    static let embeddedFile: UInt32 = 0x60035
    static let pageMeta: UInt32 = 0x20030
    static let revisionMeta: UInt32 = 0x20044
}

// MARK: - Чтение байтов

private struct Bytes {
    let b: [UInt8]

    func u8(_ o: Int) throws -> UInt32 {
        guard o >= 0, o < b.count else { throw OneNoteError.truncated }
        return UInt32(b[o])
    }

    func u16(_ o: Int) throws -> UInt32 {
        guard o >= 0, o + 2 <= b.count else { throw OneNoteError.truncated }
        return UInt32(b[o]) | UInt32(b[o + 1]) << 8
    }

    func u32(_ o: Int) throws -> UInt32 {
        guard o >= 0, o + 4 <= b.count else { throw OneNoteError.truncated }
        return UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }

    func u64(_ o: Int) throws -> UInt64 {
        guard o >= 0, o + 8 <= b.count else { throw OneNoteError.truncated }
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(b[o + i]) << UInt64(8 * i) }
        return v
    }

    func slice(_ o: Int, _ n: Int) throws -> Data {
        guard o >= 0, n >= 0, o + n <= b.count else { throw OneNoteError.truncated }
        return Data(b[o..<(o + n)])
    }

    func hex(_ o: Int, _ n: Int) throws -> String {
        guard o >= 0, n >= 0, o + n <= b.count else { throw OneNoteError.truncated }
        var s = ""
        s.reserveCapacity(n * 2)
        for i in 0..<n { s += String(format: "%02x", b[o + i]) }
        return s
    }
}

// MARK: - Разбор контейнера

private final class Container {
    let bytes: Bytes
    var spaces: [Space] = []
    var spaceIndex: [OID: Space] = [:]
    var fileData: [String: (stp: Int, cb: Int)] = [:]
    private var currentSpace: Space?
    private var currentRevision: Revision?
    private var depth = 0

    init(data: Data) {
        self.bytes = Bytes(b: [UInt8](data))
    }

    private static let fragmentMagic: UInt64 = 0xA4567AB1F5F7F4C4
    private static let nilStp: UInt64 = 0xFFFFFFFFFFFFFFFF

    func parse() throws {
        // guidFileType для .one: {7B5C52E4-D88C-4DA7-AEB1-5378D02996D3}
        let type = try bytes.hex(0, 16)
        guard type == "e4525c7b8cd8a74daeb15378d02996d3" else { throw OneNoteError.notOneNote }
        let stp = try bytes.u64(172)
        let cb = try bytes.u32(180)
        try readList(stp: Int(truncatingIfNeeded: stp), cb: Int(cb))
    }

    private func readOID(_ o: Int) throws -> OID {
        OID(guid: try bytes.hex(o, 16), n: try bytes.u32(o + 16))
    }

    private func readList(stp startStp: Int, cb startCb: Int) throws {
        depth += 1
        defer { depth -= 1 }
        guard depth < 24 else { return }

        var stp = startStp
        var cb = startCb
        var guardCounter = 0
        while stp > 0 && cb > 20 && guardCounter < 4096 {
            guardCounter += 1
            guard try bytes.u64(stp) == Container.fragmentMagic else { throw OneNoteError.unsupported("список узлов") }
            let end = stp + cb - 20
            var p = stp + 16
            while p + 4 <= end {
                let v = try bytes.u32(p)
                let fid = Int(v & 0x3ff)
                let size = Int((v >> 10) & 0x1fff)
                let sf = (v >> 23) & 3
                let cf = (v >> 25) & 3
                let bt = (v >> 27) & 0xf
                if fid == 0 || fid == 0xff || size < 4 { break }
                var q = p + 4
                var ref: (stp: Int, cb: Int)?
                if bt == 1 || bt == 2 {
                    let s: UInt64
                    switch sf {
                    case 0: s = try bytes.u64(q); q += 8
                    case 1: s = UInt64(try bytes.u32(q)); q += 4
                    case 2: s = UInt64(try bytes.u16(q)) * 8; q += 2
                    default: s = UInt64(try bytes.u32(q)) * 8; q += 4
                    }
                    let c: UInt64
                    switch cf {
                    case 0: c = UInt64(try bytes.u32(q)); q += 4
                    case 1: c = try bytes.u64(q); q += 8
                    case 2: c = UInt64(try bytes.u8(q)) * 8; q += 1
                    default: c = UInt64(try bytes.u16(q)) * 8; q += 2
                    }
                    if s == Container.nilStp || s > UInt64(bytes.b.count) || c > UInt64(bytes.b.count) {
                        ref = nil
                    } else {
                        ref = (Int(s), Int(c))
                    }
                }
                try visit(fid: fid, ref: ref, q: q, end: p + size)
                p += size
            }
            let nextStp = try bytes.u64(end)
            let nextCb = try bytes.u32(end + 8)
            if nextStp == Container.nilStp || nextStp == 0 { break }
            stp = Int(truncatingIfNeeded: nextStp)
            cb = Int(nextCb)
        }
    }

    private func visit(fid: Int, ref: (stp: Int, cb: Int)?, q: Int, end: Int) throws {
        switch fid {
        case 0x008: // ObjectSpaceManifestListReferenceFND
            let id = try readOID(q)
            let space: Space
            if let s = spaceIndex[id] {
                space = s
            } else {
                space = Space(id: id)
                spaceIndex[id] = space
                spaces.append(space)
            }
            currentSpace = space
            if let ref { try readList(stp: ref.stp, cb: ref.cb) }

        case 0x010, 0x0b0, 0x090: // списки ревизий, групп объектов, хранилища файлов
            if let ref { try readList(stp: ref.stp, cb: ref.cb) }

        case 0x01b, 0x01e, 0x01f: // начало ревизии
            guard let space = currentSpace else { return }
            let rid = try readOID(q)
            let dep = try readOID(q + 20)
            let rev = Revision(rid: rid, dep: dep)
            if let parent = space.revisions.last(where: { $0.rid == dep }) {
                rev.objs = parent.objs
                rev.order = parent.order
                rev.gid = parent.gid
            }
            space.revisions.append(rev)
            currentRevision = rev

        case 0x024: // GlobalIdTableEntryFNDX
            guard let rev = currentRevision else { return }
            let index = Int(try bytes.u32(q))
            rev.gid[index] = try bytes.hex(q + 4, 16)

        case 0x025: // GlobalIdTableEntry2FNDX
            guard let rev = currentRevision else { return }
            let from = Int(try bytes.u32(q))
            let to = Int(try bytes.u32(q + 4))
            rev.gid[to] = rev.gid[from]

        case 0x026: // GlobalIdTableEntry3FNDX
            guard let rev = currentRevision else { return }
            let from = Int(try bytes.u32(q))
            let count = Int(try bytes.u32(q + 4))
            let to = Int(try bytes.u32(q + 8))
            if count > 0 && count < 1_000_000 {
                for i in 0..<count { rev.gid[to + i] = rev.gid[from + i] }
            }

        case 0x02d, 0x02e, 0x0a4, 0x0a5, 0x0c4, 0x0c5: // объявления объектов со свойствами
            guard let rev = currentRevision, let ref else { return }
            let oid = try bytes.u32(q)
            let jcid = try bytes.u32(q + 4)
            let id = OID(guid: rev.gid[Int(oid >> 8)] ?? "", n: oid & 0xff)
            let props = (try? parseProps(ref: ref, rev: rev)) ?? []
            rev.set(Obj(id: id, jcid: jcid, props: props))

        case 0x072, 0x073: // объект, указывающий на файл в хранилище (картинка, вложение)
            guard let rev = currentRevision else { return }
            let oid = try bytes.u32(q)
            let jcid = try bytes.u32(q + 4)
            let id = OID(guid: rev.gid[Int(oid >> 8)] ?? "", n: oid & 0xff)
            var p = q + 8 + (fid == 0x072 ? 1 : 4)
            let n = Int(try bytes.u32(p))
            p += 4
            guard n >= 0, n < 4096 else { return }
            let refString = utf16String(try bytes.slice(p, 2 * n))
            p += 2 * n
            let n2 = Int(try bytes.u32(p))
            p += 4
            guard n2 >= 0, n2 < 256 else { return }
            let ext = utf16String(try bytes.slice(p, 2 * n2))
            let obj = Obj(id: id, jcid: jcid, props: [])
            if let l = refString.firstIndex(of: "{"), let r = refString.firstIndex(of: "}"), l < r {
                let inner = refString[refString.index(after: l)..<r]
                obj.file = (Container.guidKey(String(inner)), ext)
            }
            rev.set(obj)

        case 0x094: // FileDataStoreObjectReferenceFND
            guard let ref else { return }
            fileData[try bytes.hex(q, 16)] = (ref.stp, ref.cb)

        default:
            break
        }
    }

    /// GUID из текста «4B6544BE-008C-41BF-A3E8-5448E291F246» в тот же вид, что и hex из файла
    /// (первые три группы хранятся в little-endian).
    static func guidKey(_ s: String) -> String {
        let hex = s.replacingOccurrences(of: "-", with: "").lowercased()
        guard hex.count == 32 else { return hex }
        let chars = Array(hex)
        func part(_ a: Int, _ n: Int, reversed: Bool) -> String {
            var pairs: [String] = []
            var i = a
            while i < a + n {
                pairs.append(String(chars[i...i + 1]))
                i += 2
            }
            return (reversed ? pairs.reversed() : pairs).joined()
        }
        return part(0, 8, reversed: true) + part(8, 4, reversed: true) + part(12, 4, reversed: true)
            + part(16, 4, reversed: false) + part(20, 12, reversed: false)
    }

    // MARK: Наборы свойств

    private func parseProps(ref: (stp: Int, cb: Int), rev: Revision) throws -> [Prop] {
        var p = ref.stp

        func stream(_ at: Int) throws -> (ids: [UInt32], next: Int, extended: Bool, noOsids: Bool) {
            let h = try bytes.u32(at)
            let n = Int(h & 0xffffff)
            guard n < 1_000_000 else { throw OneNoteError.truncated }
            var ids: [UInt32] = []
            ids.reserveCapacity(n)
            for i in 0..<n { ids.append(try bytes.u32(at + 4 + 4 * i)) }
            return (ids, at + 4 + 4 * n, (h >> 30) & 1 == 1, (h >> 31) & 1 == 1)
        }

        let oidStream = try stream(p)
        p = oidStream.next
        var osids: [UInt32] = []
        if !oidStream.noOsids {
            let s = try stream(p)
            osids = s.ids
            p = s.next
        }
        if oidStream.extended {
            let s = try stream(p)
            p = s.next
        }

        var oidCursor = 0
        var osidCursor = 0

        func nextOID() -> OID {
            defer { oidCursor += 1 }
            guard oidCursor < oidStream.ids.count else { return OID(guid: "", n: 0) }
            let c = oidStream.ids[oidCursor]
            return OID(guid: rev.gid[Int(c >> 8)] ?? "", n: c & 0xff)
        }
        func nextOSID() -> UInt64 {
            defer { osidCursor += 1 }
            guard osidCursor < osids.count else { return 0 }
            return UInt64(osids[osidCursor])
        }

        func propertySet(_ at: Int, depth: Int) throws -> (props: [Prop], next: Int) {
            guard depth < 8 else { throw OneNoteError.truncated }
            var p = at
            let count = Int(try bytes.u16(p))
            p += 2
            var ids: [UInt32] = []
            for i in 0..<count { ids.append(try bytes.u32(p + 4 * i)) }
            p += 4 * count
            var out: [Prop] = []
            for pid in ids {
                let type = (pid >> 26) & 0x1f
                var prop = Prop(id: pid & 0x3ffffff, type: type)
                switch type {
                case 0x1: break
                case 0x2: prop.int = UInt64((pid >> 31) & 1)
                case 0x3: prop.int = UInt64(try bytes.u8(p)); p += 1
                case 0x4: prop.int = UInt64(try bytes.u16(p)); p += 2
                case 0x5: prop.int = UInt64(try bytes.u32(p)); p += 4
                case 0x6: prop.int = try bytes.u64(p); p += 8
                case 0x7:
                    let l = Int(try bytes.u32(p))
                    prop.data = try bytes.slice(p + 4, l)
                    p += 4 + l
                case 0x8: prop.oids = [nextOID()]
                case 0x9:
                    let l = Int(try bytes.u32(p)); p += 4
                    guard l < 1_000_000 else { throw OneNoteError.truncated }
                    for _ in 0..<l { prop.oids.append(nextOID()) }
                case 0xa: prop.int = nextOSID()
                case 0xb:
                    let l = Int(try bytes.u32(p)); p += 4
                    guard l < 1_000_000 else { throw OneNoteError.truncated }
                    for i in 0..<l {
                        let v = nextOSID()
                        if i == 0 { prop.int = v }
                    }
                case 0xc:
                    break
                case 0xd:
                    let l = Int(try bytes.u32(p)); p += 4
                    guard l < 1_000_000 else { throw OneNoteError.truncated }
                case 0x10:
                    let l = Int(try bytes.u32(p)); p += 4
                    if l > 0 {
                        let sub = try bytes.u32(p); p += 4
                        guard (sub >> 26) & 0x1f == 0x11 else { throw OneNoteError.unsupported("массив свойств") }
                        for _ in 0..<l {
                            let r = try propertySet(p, depth: depth + 1)
                            p = r.next
                        }
                    }
                case 0x11:
                    let r = try propertySet(p, depth: depth + 1)
                    p = r.next
                default:
                    throw OneNoteError.unsupported("тип свойства \(type)")
                }
                out.append(prop)
            }
            return (out, p)
        }

        return try propertySet(p, depth: 0).props
    }

    func fileBytes(_ guid: String) -> Data? {
        guard let loc = fileData[guid] else { return nil }
        guard let length = try? bytes.u64(loc.stp + 16), length < UInt64(bytes.b.count) else { return nil }
        return try? bytes.slice(loc.stp + 36, Int(length))
    }
}

private func utf16String(_ data: Data) -> String {
    var units: [UInt16] = []
    units.reserveCapacity(data.count / 2)
    var i = data.startIndex
    while i + 1 < data.endIndex {
        units.append(UInt16(data[i]) | UInt16(data[i + 1]) << 8)
        i += 2
    }
    while units.last == 0 { units.removeLast() }
    return String(decoding: units, as: UTF16.self)
}

// MARK: - Публичный разбор

enum OneNoteReader {
    static func read(url: URL) throws -> ONSection {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try read(data: data)
    }

    static func read(data: Data) throws -> ONSection {
        let container = Container(data: data)
        try container.parse()
        return build(container)
    }

    // MARK: Сборка страниц

    private static func build(_ c: Container) -> ONSection {
        var pageSpaces: [(space: Space, rev: Revision)] = []
        for space in c.spaces {
            // Актуальная ревизия — с самой поздней отметкой изменения среди ревизий, где есть страница.
            var best: (rev: Revision, stamp: UInt64, index: Int)?
            for (i, rev) in space.revisions.enumerated() {
                guard rev.objs.values.contains(where: { $0.jcid == JC.page }) else { continue }
                var stamp: UInt64 = 0
                for o in rev.objs.values where o.jcid == JC.revisionMeta {
                    stamp = max(stamp, o.prop(PID.modified)?.int ?? 0)
                }
                if best == nil || stamp >= best!.stamp {
                    best = (rev, stamp, i)
                }
            }
            if let best { pageSpaces.append((space, best.rev)) }
        }

        // Порядок страниц — как в разделе: раздел → серии страниц → пространство страницы.
        var ordered: [(space: Space, rev: Revision)] = []
        var used = Set<OID>()
        for space in c.spaces {
            guard let rev = space.revisions.last(where: { r in r.objs.values.contains { $0.jcid == JC.section } }),
                  let section = rev.objs.values.first(where: { $0.jcid == JC.section }) else { continue }
            for childID in section.oidList(PID.elementChildren) {
                guard let series = rev.objs[childID], series.jcid == JC.pageSeries,
                      let osid = series.prop(PID.osidPage)?.int else { continue }
                // В файле это CompactID: младшие 8 бит — номер, остальное — индекс в таблице GUID.
                let index = Int(osid >> 8)
                let n = UInt32(osid & 0xff)
                guard let guid = rev.gid[index] else { continue }
                let target = OID(guid: guid, n: n)
                if let found = pageSpaces.first(where: { $0.space.id == target }), !used.contains(target) {
                    ordered.append(found)
                    used.insert(target)
                }
            }
        }
        for item in pageSpaces where !used.contains(item.space.id) {
            ordered.append(item)
        }

        var pages: [ONPage] = []
        for item in ordered {
            if let page = buildPage(c, rev: item.rev) { pages.append(page) }
        }
        return ONSection(pages: pages)
    }

    private static func filetime(_ v: UInt64?) -> Date? {
        guard let v, v > 0 else { return nil }
        let seconds = Double(v) / 10_000_000.0 - 11_644_473_600.0
        guard seconds > 0, seconds < 4_102_444_800 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func buildPage(_ c: Container, rev: Revision) -> ONPage? {
        guard let page = rev.objs.values.first(where: { $0.jcid == JC.page }) else { return nil }
        let meta = rev.objs.values.first(where: { $0.jcid == JC.pageMeta })
        let revMeta = rev.objs.values.first(where: { $0.jcid == JC.revisionMeta })

        var title = ""
        if let t = meta?.prop(PID.cachedTitle) { title = utf16String(t.data) }
        let level = Int(meta?.prop(PID.pageLevel)?.int ?? 1)

        let ctx = PageContext(container: c, rev: rev)

        // Область заголовка: первая строка — название, остальные (дата, время) идут под ним.
        var headerLines: [String] = []
        if let titleObj = page.oidList(PID.elementChildren).compactMap({ rev.objs[$0] }).first(where: { $0.jcid == JC.title }) {
            var texts: [String] = []
            ctx.collectTexts(titleObj, into: &texts, seen: [])
            let nonEmpty = texts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if title.isEmpty, let first = nonEmpty.first { title = first }
            if nonEmpty.count > 1 { headerLines = Array(nonEmpty.dropFirst()) }
        }

        var blocks: [ONBlock] = []
        for id in page.oidList(PID.elementChildren) {
            guard let o = rev.objs[id], o.jcid != JC.title else { continue }
            ctx.walk(o, level: 0, into: &blocks)
        }

        return ONPage(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            created: filetime(meta?.prop(PID.created)?.int),
            modified: filetime(revMeta?.prop(PID.modified)?.int),
            level: level,
            headerLines: headerLines,
            blocks: blocks
        )
    }
}

// MARK: - Обход дерева страницы

private final class PageContext {
    let c: Container
    let rev: Revision
    var seen = Set<OID>()

    init(container: Container, rev: Revision) {
        self.c = container
        self.rev = rev
    }

    func object(_ id: OID) -> Obj? { rev.objs[id] }

    func decodeText(_ o: Obj) -> String? {
        if let p = o.prop(PID.richTextUnicode) {
            return utf16String(p.data)
        }
        if let p = o.prop(PID.textAscii) {
            let lang = Int(o.prop(PID.langID)?.int ?? 0)
            // Кириллические языки хранятся в однобайтовой кодировке Windows-1251.
            let cyrillic: Set<Int> = [1049, 1058, 1059, 1026, 1087, 1092, 1093, 1088, 1071, 1064]
            let encoding: String.Encoding = cyrillic.contains(lang) ? .windowsCP1251 : .windowsCP1252
            var d = p.data
            while d.last == 0 { d.removeLast() }
            return String(data: d, encoding: encoding) ?? String(decoding: d, as: UTF8.self)
        }
        return nil
    }

    func collectTexts(_ o: Obj, into out: inout [String], seen visited: Set<OID>) {
        var visited = visited
        guard !visited.contains(o.id) else { return }
        visited.insert(o.id)
        if o.jcid == JC.richText {
            out.append(cleanLineBreaks(decodeText(o) ?? ""))
        }
        for key in [PID.elementChildren, PID.contentChildren] {
            for id in o.oidList(key) {
                if let child = object(id) { collectTexts(child, into: &out, seen: visited) }
            }
        }
    }

    func cleanLineBreaks(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{000B}", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\0", with: "")
    }

    func walk(_ o: Obj, level: Int, into blocks: inout [ONBlock]) {
        guard !seen.contains(o.id) else { return }
        seen.insert(o.id)

        switch o.jcid {
        case JC.outline:
            for id in o.oidList(PID.elementChildren) {
                if let child = object(id) { walk(child, level: level, into: &blocks) }
            }

        case JC.outlineElement:
            let list = listKind(of: o)
            for id in o.oidList(PID.contentChildren) {
                guard let child = object(id) else { continue }
                if child.jcid == JC.richText {
                    seen.insert(child.id)
                    blocks.append(paragraph(child, level: level, list: list))
                } else {
                    walk(child, level: level, into: &blocks)
                }
            }
            for id in o.oidList(PID.elementChildren) {
                if let child = object(id) { walk(child, level: level + 1, into: &blocks) }
            }

        case JC.richText:
            blocks.append(paragraph(o, level: level, list: nil))

        case JC.image:
            if let block = image(o) { blocks.append(block) }

        case JC.embeddedFile:
            if let block = embeddedFile(o) { blocks.append(block) }

        case JC.table:
            blocks.append(.table(rows: tableRows(o)))

        default:
            break
        }
    }

    // MARK: Списки

    func listKind(of o: Obj) -> ONListKind? {
        for p in o.props where p.type == 0x9 || p.type == 0x8 {
            for id in p.oids {
                guard let child = object(id), child.jcid == JC.numberList else { continue }
                for q in child.props where q.type == 0x7 {
                    let s = utf16String(q.data)
                    if s.unicodeScalars.contains(where: { $0.value < 0x20 && $0.value != 0 }) { return .numbered }
                }
                return .bullet
            }
        }
        return nil
    }

    // MARK: Абзацы

    func paragraph(_ o: Obj, level: Int, list: ONListKind?) -> ONBlock {
        let text = decodeText(o) ?? ""
        let units = Array(text.utf16)

        var indexes: [Int] = []
        if let p = o.prop(PID.textRunIndex) {
            let d = [UInt8](p.data)
            var i = 0
            while i + 4 <= d.count {
                indexes.append(Int(UInt32(d[i]) | UInt32(d[i + 1]) << 8 | UInt32(d[i + 2]) << 16 | UInt32(d[i + 3]) << 24))
                i += 4
            }
        }
        let formats = o.oidList(PID.textRunFormatting).map { object($0) }
        var style: Obj?
        if let styleRef = o.prop(PID.paragraphStyle)?.oids.first {
            style = object(styleRef)
        }
        var styleID = "p"
        if let idProp = style?.prop(PID.paragraphStyleID) {
            styleID = utf16String(idProp.data)
        }

        var runs: [ONRun] = []
        var start = 0
        let bounds = indexes + [units.count]
        for (k, rawEnd) in bounds.enumerated() {
            let end = min(max(rawEnd, start), units.count)
            if end > start {
                let slice = String(decoding: units[start..<end], as: UTF16.self)
                var run = format(object: k < formats.count ? formats[k] : nil, style: style)
                var seg = cleanLineBreaks(slice)
                if let marker = seg.range(of: "HYPERLINK \"") {
                    let rest = seg[marker.upperBound...]
                    if let close = rest.firstIndex(of: "\"") {
                        run.link = String(rest[..<close])
                        var head = String(seg[..<marker.lowerBound])
                        // Перед словом HYPERLINK стоит служебный символ U+FDDF — убираем его.
                        if let last = head.utf16.last, last == 0xFDDF {
                            head = String(decoding: Array(head.utf16.dropLast()), as: UTF16.self)
                        }
                        seg = head + String(rest[rest.index(after: close)...])
                    }
                }
                if !seg.isEmpty {
                    run.text = seg
                    runs.append(run)
                }
            }
            start = end
        }
        return .paragraph(level: level, style: styleID, list: list, runs: runs)
    }

    func format(object f: Obj?, style: Obj?) -> ONRun {
        func prop(_ pid: UInt32) -> Prop? {
            if let p = f?.prop(pid) { return p }
            return style?.prop(pid)
        }
        var run = ONRun(text: "")
        run.bold = prop(PID.bold)?.int == 1
        run.italic = prop(PID.italic)?.int == 1
        run.underline = prop(PID.underline)?.int == 1
        run.strike = prop(PID.strike)?.int == 1
        run.superscript = prop(PID.superscript)?.int == 1
        run.isSubscript = prop(PID.subscripted)?.int == 1
        if let p = prop(PID.fontName) {
            let name = utf16String(p.data)
            if !name.isEmpty { run.fontName = name }
        }
        if let p = prop(PID.fontSize), p.int > 0 { run.sizeHalfPoints = Int(p.int) }
        run.color = colorRef(prop(PID.fontColor)?.int)
        run.highlight = colorRef(prop(PID.highlight)?.int)
        return run
    }

    /// COLORREF 0x00BBGGRR → 0xRRGGBB. Значение с 0xFF в старшем байте означает «авто / нет».
    func colorRef(_ v: UInt64?) -> UInt32? {
        guard let v, v <= 0xFFFFFFFF, (v >> 24) == 0 else { return nil }
        let r = UInt32(v & 0xff), g = UInt32((v >> 8) & 0xff), b = UInt32((v >> 16) & 0xff)
        return r << 16 | g << 8 | b
    }

    // MARK: Картинки и файлы

    func fileObject(of o: Obj) -> Obj? {
        for p in o.props where p.type == 0x8 || p.type == 0x9 {
            for id in p.oids {
                if let child = object(id), child.file != nil { return child }
            }
        }
        return nil
    }

    func image(_ o: Obj) -> ONBlock? {
        guard let container = fileObject(of: o), let file = container.file,
              let data = c.fileBytes(file.guid) else { return nil }
        var alt = ""
        for p in o.props where p.type == 0x7 {
            let s = utf16String(p.data)
            if !s.isEmpty && s.count < 400 { alt = s; break }
        }
        return .image(data: data, ext: file.ext.lowercased(), alt: alt)
    }

    func embeddedFile(_ o: Obj) -> ONBlock? {
        guard let container = fileObject(of: o), let file = container.file,
              let data = c.fileBytes(file.guid) else { return nil }
        var name = ""
        for p in o.props where p.type == 0x7 {
            let s = utf16String(p.data)
            if !s.isEmpty && s.count < 260 && !s.unicodeScalars.contains(where: { $0.value < 0x20 }) {
                name = s
                break
            }
        }
        return .file(name: name, ext: file.ext, data: data)
    }

    // MARK: Таблицы

    func tableRows(_ table: Obj) -> [[String]] {
        var rows: [[String]] = []
        for rowID in table.oidList(PID.elementChildren) {
            guard let row = object(rowID), row.jcid == JC.tableRow else { continue }
            var cells: [String] = []
            for cellID in row.oidList(PID.elementChildren) {
                guard let cell = object(cellID), cell.jcid == JC.tableCell else { continue }
                var texts: [String] = []
                collectTexts(cell, into: &texts, seen: [])
                cells.append(texts.filter { !$0.isEmpty }.joined(separator: " / "))
                markSeen(cell)
            }
            rows.append(cells)
        }
        return rows
    }

    func markSeen(_ o: Obj) {
        seen.insert(o.id)
        for key in [PID.elementChildren, PID.contentChildren] {
            for id in o.oidList(key) {
                if let child = object(id), !seen.contains(child.id) { markSeen(child) }
            }
        }
    }
}
