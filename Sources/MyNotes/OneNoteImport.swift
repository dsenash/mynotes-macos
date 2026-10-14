import AppKit

// Импорт родных файлов разделов OneNote (.one): файл становится проектом, каждая страница — заметкой.

extension Store {
    func importOneSection(_ url: URL, into parent: UUID?, report: inout ImportReport) throws {
        let section: ONSection
        do {
            section = try OneNoteReader.read(url: url)
        } catch {
            report.failed.append("\(url.lastPathComponent) — \(error.localizedDescription)")
            return
        }
        guard !section.pages.isEmpty else {
            report.failed.append("\(url.lastPathComponent) — страниц не найдено")
            return
        }

        let projectName = url.deletingPathExtension().lastPathComponent
        let projectID = try insertProject(name: projectName.isEmpty ? "Раздел OneNote" : projectName, parent: parent)
        report.projects += 1

        for page in section.pages {
            let rendered = OneNoteRenderer.render(page)
            let mutable = NSMutableAttributedString(attributedString: rendered.text)
            TextTools.normalizeColors(mutable)
            let plain = mutable.string.replacingOccurrences(of: "\u{FFFC}", with: " ")
            let title = page.title.isEmpty ? "Без названия" : page.title
            let created = page.created ?? page.modified ?? Date()
            let updated = page.modified ?? created
            try insertNote(
                project: projectID, title: title, plain: plain,
                body: BodyCodec.encode(mutable), created: created, updated: updated
            )
            report.notes += 1
            if rendered.skippedImages > 0 {
                report.warnings.append("«\(title)»: картинок в неподдерживаемом формате — \(rendered.skippedImages)")
            }
        }
    }
}

// MARK: - Превращение страницы в форматированный текст

enum OneNoteRenderer {
    struct Result {
        var text: NSAttributedString
        var skippedImages: Int
    }

    private static let monospaceNames = ["consolas", "courier", "menlo", "monaco", "lucida console", "cascadia", "source code", "fira code"]

    static func render(_ page: ONPage) -> Result {
        let out = NSMutableAttributedString()
        var skipped = 0
        let baseSize = dominantSize(page)
        let basePoints = TextTools.defaultFont.pointSize

        // Название страницы — первой строкой: по ней MyNotes строит заголовок заметки.
        let title = page.title.isEmpty ? "Без названия" : page.title
        out.append(NSAttributedString(string: title + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: (basePoints * 1.5).rounded(), weight: .bold),
            .paragraphStyle: paragraphStyle(level: 0, listIndent: 0, after: 6)
        ]))
        for line in page.headerLines {
            out.append(NSAttributedString(string: line + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: max(11, basePoints - 2)),
                .foregroundColor: NSColor.gray,
                .paragraphStyle: paragraphStyle(level: 0, listIndent: 0, after: 0)
            ]))
        }
        out.append(NSAttributedString(string: "\n", attributes: [.font: TextTools.defaultFont]))

        var numbering: [Int: Int] = [:]
        var blankRun = 0

        for block in page.blocks {
            switch block {
            case .paragraph(let level, _, let list, let runs):
                let isBlank = runs.allSatisfy { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                if isBlank {
                    blankRun += 1
                    if blankRun <= 2 {
                        out.append(NSAttributedString(string: "\n", attributes: [.font: TextTools.defaultFont]))
                    }
                    continue
                }
                blankRun = 0

                var prefix = ""
                var listIndent: CGFloat = 0
                switch list {
                case .some(.bullet):
                    prefix = "•\u{2002}"
                    listIndent = 16
                    numbering = numbering.filter { $0.key < level }
                case .some(.numbered):
                    let n = (numbering[level] ?? 0) + 1
                    numbering[level] = n
                    numbering = numbering.filter { $0.key <= level }
                    prefix = "\(n).\u{2002}"
                    listIndent = 20
                case .none:
                    numbering.removeAll()
                }

                let style = paragraphStyle(level: level, listIndent: listIndent, after: 3)
                let line = NSMutableAttributedString()
                if !prefix.isEmpty {
                    line.append(NSAttributedString(string: prefix, attributes: [.font: TextTools.defaultFont]))
                }
                for run in runs {
                    line.append(NSAttributedString(string: run.text, attributes: attributes(for: run, baseSize: baseSize, basePoints: basePoints)))
                }
                line.append(NSAttributedString(string: "\n", attributes: [.font: TextTools.defaultFont]))
                line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
                out.append(line)

            case .image(let data, _, _):
                blankRun = 0
                if let attachment = imageAttachment(from: data) {
                    out.append(NSAttributedString(attachment: attachment))
                    out.append(NSAttributedString(string: "\n", attributes: [.font: TextTools.defaultFont]))
                } else {
                    skipped += 1
                }

            case .file(let name, let ext, let data):
                blankRun = 0
                var filename = name.isEmpty ? "Файл OneNote" : name
                let cleanExt = ext.hasPrefix(".") ? String(ext.dropFirst()) : ext
                if !cleanExt.isEmpty && !filename.lowercased().hasSuffix("." + cleanExt.lowercased()) {
                    filename += "." + cleanExt
                }
                let wrapper = FileWrapper(regularFileWithContents: data)
                wrapper.preferredFilename = filename
                out.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
                out.append(NSAttributedString(string: "\n", attributes: [.font: TextTools.defaultFont]))

            case .table(let rows):
                blankRun = 0
                for row in rows {
                    let text = row.joined(separator: "  |  ")
                    out.append(NSAttributedString(string: text + "\n", attributes: [
                        .font: TextTools.defaultFont,
                        .paragraphStyle: paragraphStyle(level: 0, listIndent: 0, after: 2)
                    ]))
                }
            }
        }
        return Result(text: out, skippedImages: skipped)
    }

    // MARK: Вспомогательные функции

    /// Самый частый размер шрифта на странице (в половинках пункта) — он считается «обычным».
    private static func dominantSize(_ page: ONPage) -> Int {
        var counts: [Int: Int] = [:]
        for block in page.blocks {
            guard case .paragraph(_, _, _, let runs) = block else { continue }
            for run in runs {
                if let s = run.sizeHalfPoints { counts[s, default: 0] += run.text.count }
            }
        }
        return counts.max(by: { $0.value < $1.value })?.key ?? 22
    }

    private static func paragraphStyle(level: Int, listIndent: CGFloat, after: CGFloat) -> NSParagraphStyle {
        let ps = NSMutableParagraphStyle()
        let indent = CGFloat(min(level, 8)) * 24
        ps.firstLineHeadIndent = indent
        ps.headIndent = indent + listIndent
        ps.paragraphSpacing = after
        return ps
    }

    private static func attributes(for run: ONRun, baseSize: Int, basePoints: CGFloat) -> [NSAttributedString.Key: Any] {
        var scale = 1.0
        if let s = run.sizeHalfPoints, baseSize > 0 {
            scale = Double(s) / Double(baseSize)
        }
        if run.superscript || run.isSubscript { scale *= 0.75 }
        scale = min(max(scale, 0.6), 3.0)
        let size = (basePoints * CGFloat(scale)).rounded()

        var font: NSFont
        if let name = run.fontName?.lowercased(), monospaceNames.contains(where: { name.contains($0) }) {
            font = NSFont.monospacedSystemFont(ofSize: max(10, size - 1), weight: .regular)
        } else {
            font = NSFont.systemFont(ofSize: size)
        }
        var traits: NSFontTraitMask = []
        if run.bold { traits.insert(.boldFontMask) }
        if run.italic { traits.insert(.italicFontMask) }
        if !traits.isEmpty {
            font = NSFontManager.shared.convert(font, toHaveTrait: traits)
        }

        var attrs: [NSAttributedString.Key: Any] = [.font: font]
        if let c = run.color {
            attrs[.foregroundColor] = color(c)
        }
        if let h = run.highlight {
            attrs[.backgroundColor] = color(h)
        }
        if run.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if run.strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if run.superscript { attrs[.baselineOffset] = size * 0.4 }
        if run.isSubscript { attrs[.baselineOffset] = -size * 0.25 }
        if let link = run.link, let url = URL(string: link) {
            attrs[.link] = url
        }
        return attrs
    }

    private static func color(_ rgb: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((rgb >> 16) & 0xff) / 255,
            green: CGFloat((rgb >> 8) & 0xff) / 255,
            blue: CGFloat(rgb & 0xff) / 255,
            alpha: 1
        )
    }

    /// Картинка в виде вложения: уменьшается до ширины 720 и сохраняется как PNG (как при вставке в редакторе).
    private static func imageAttachment(from data: Data) -> NSTextAttachment? {
        guard let image = NSImage(data: data),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let maxWidth: CGFloat = 720
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        guard w > 0, h > 0 else { return nil }
        let scale = min(1, maxWidth / w)
        let nw = max(1, Int(w * scale)), nh = max(1, Int(h * scale))
        guard let ctx = CGContext(
            data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        guard let scaled = ctx.makeImage(),
              let png = NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:]) else { return nil }
        let wrapper = FileWrapper(regularFileWithContents: png)
        wrapper.preferredFilename = "OneNote-картинка.png"
        let attachment = NSTextAttachment(fileWrapper: wrapper)
        attachment.image = NSImage(cgImage: scaled, size: NSSize(width: nw, height: nh))
        return attachment
    }
}
