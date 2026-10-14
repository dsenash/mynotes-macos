import AppKit

struct Project: Identifiable, Hashable {
    let id: UUID
    var parentID: UUID?
    var name: String
    var sort: Int
    var created: Date
    var colorHex: String? = nil
    /// Битовая маска: 1 — жирный, 2 — курсив (начертание названия), 4 — «скрываемый» проект.
    var fontStyle: Int = 0
    /// Время последнего изменения (для слияния при синхронизации).
    var updated: Date = Date(timeIntervalSince1970: 0)

    var isBold: Bool { fontStyle & 1 != 0 }
    var isItalic: Bool { fontStyle & 2 != 0 }
    var isHideable: Bool { fontStyle & 4 != 0 }
}

struct NoteMeta: Identifiable, Hashable {
    let id: UUID
    var projectID: UUID?
    var title: String
    var created: Date
    var updated: Date
}

enum SidebarRow: Identifiable {
    case project(Project, Int)
    case note(NoteMeta, Int)

    var id: String {
        switch self {
        case .project(let p, _): return "p-" + p.id.uuidString
        case .note(let n, _): return "n-" + n.id.uuidString
        }
    }
}

enum ExportScope {
    case all
    case project(UUID)
    case note(UUID)
}

// MARK: - Формат обмена (.mynotes)

struct Archive: Codable {
    var format: String = "MyNotes"
    var version: Int = 2
    var exportedAt: Date = Date()
    var projects: [ArchivedProject]
    var notes: [ArchivedNote]
    var deviceName: String? = nil
}

struct ArchivedProject: Codable {
    var id: String
    var parentID: String?
    var name: String
    var sort: Int
    var color: String? = nil
    var fontStyle: Int? = nil
    var updated: Date? = nil
}

struct ArchivedNote: Codable {
    var id: String
    var projectID: String?
    var title: String
    var created: Date
    var updated: Date
    var body: Data?
}

// MARK: - Кодирование текста заметки

/// Тело заметки хранится как 1 байт формата + данные:
/// 0 — RTF (без вложений), 1 — сериализованный RTFD (с картинками и файлами).
enum BodyCodec {
    static func encode(_ s: NSAttributedString) -> Data {
        let full = NSRange(location: 0, length: s.length)
        var hasAttachment = false
        s.enumerateAttribute(.attachment, in: full) { value, _, stop in
            if value != nil {
                hasAttachment = true
                stop.pointee = true
            }
        }
        if hasAttachment,
           let wrapper = try? s.fileWrapper(from: full, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]),
           let data = wrapper.serializedRepresentation {
            return Data([1]) + data
        }
        if let data = try? s.data(from: full, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            return Data([0]) + data
        }
        return Data([0])
    }

    static func decode(_ data: Data) -> NSAttributedString? {
        guard let kind = data.first else { return nil }
        let payload = Data(data.dropFirst())
        if kind == 1 {
            guard let wrapper = FileWrapper(serializedRepresentation: payload) else { return nil }
            return NSAttributedString(rtfdFileWrapper: wrapper, documentAttributes: nil)
        }
        if payload.isEmpty { return NSAttributedString(string: "") }
        return try? NSAttributedString(
            data: payload,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        )
    }
}

enum TextTools {
    static let defaultFont = NSFont.systemFont(ofSize: 15)

    static func title(from plain: String) -> String {
        let cleaned = plain.replacingOccurrences(of: "\u{FFFC}", with: "")
        let junk = CharacterSet(charactersIn: "•☐☑").union(.whitespaces)
        for line in cleaned.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: junk)
            if !t.isEmpty { return String(t.prefix(80)) }
        }
        return "Новая заметка"
    }

    /// Убирает «зашитые» чёрные/белые цвета текста и фона, чтобы заметки
    /// одинаково читались в светлой и тёмной теме.
    static func normalizeColors(_ s: NSMutableAttributedString) {
        let full = NSRange(location: 0, length: s.length)
        for key in [NSAttributedString.Key.foregroundColor, .backgroundColor] {
            s.enumerateAttribute(key, in: full) { value, range, _ in
                guard let color = (value as? NSColor)?.usingColorSpace(.sRGB) else { return }
                let gray = abs(color.redComponent - color.greenComponent) < 0.05
                    && abs(color.greenComponent - color.blueComponent) < 0.05
                if gray && (color.brightnessComponent < 0.12 || color.brightnessComponent > 0.9) {
                    s.removeAttribute(key, range: range)
                }
            }
        }
    }
}
