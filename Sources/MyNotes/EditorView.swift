import AppKit
import SwiftUI

// MARK: - Текстовое поле с кликабельными чекбоксами

final class NotesTextView: NSTextView {
    private var attachmentTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = attachmentTrackingArea { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        attachmentTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let tip = attachmentToolTip(at: convert(event.locationInWindow, from: nil))
        if toolTip != tip { toolTip = tip }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if toolTip != nil { toolTip = nil }
    }

    /// Вложение под точкой (в координатах вью) или nil.
    private func attachment(at point: NSPoint) -> NSTextAttachment? {
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let origin = textContainerOrigin
        let local = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        var fraction: CGFloat = 0
        let glyph = lm.glyphIndex(for: local, in: tc, fractionOfDistanceThroughGlyph: &fraction)
        let idx = lm.characterIndexForGlyph(at: glyph)
        guard idx < storage.length,
              let attachment = storage.attribute(.attachment, at: idx, effectiveRange: nil) as? NSTextAttachment else { return nil }
        let rect = lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: tc)
        guard rect.insetBy(dx: -2, dy: -2).contains(local) else { return nil }
        return attachment
    }

    /// Подсказка для вложения под курсором: имя файла и размер.
    private func attachmentToolTip(at point: NSPoint) -> String? {
        guard let attachment = attachment(at: point) else { return nil }
        return Self.describe(attachment)
    }

    // MARK: Контекстное меню вложения

    override func menu(for event: NSEvent) -> NSMenu? {
        let base = super.menu(for: event)
        guard let attachment = attachment(at: convert(event.locationInWindow, from: nil)),
              attachment.fileWrapper != nil else { return base }
        let menu = base ?? NSMenu()
        let item = NSMenuItem(title: "Сохранить как…", action: #selector(saveAttachmentAs(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = attachment
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }

    @objc private func saveAttachmentAs(_ sender: NSMenuItem) {
        guard let attachment = sender.representedObject as? NSTextAttachment,
              let wrapper = attachment.fileWrapper else { return }
        let panel = NSSavePanel()
        panel.title = "Сохранить файл"
        panel.prompt = "Сохранить"
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = wrapper.preferredFilename ?? wrapper.filename ?? "Файл"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let target = panel.url else { return }
        do {
            try wrapper.write(to: target, options: .atomic, originalContentsURL: nil)
        } catch {
            Dialogs.info(title: "Не удалось сохранить файл", message: error.localizedDescription)
        }
    }

    static func describe(_ attachment: NSTextAttachment) -> String {
        guard let wrapper = attachment.fileWrapper else { return "Вложение" }
        let name = wrapper.preferredFilename ?? wrapper.filename ?? "Без имени"
        let size = byteCount(of: wrapper)
        let sizeText = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        return "\(name)\nРазмер: \(sizeText)\nДвойной щелчок — открыть"
    }

    private static func byteCount(of wrapper: FileWrapper) -> Int64 {
        if wrapper.isRegularFile { return Int64(wrapper.regularFileContents?.count ?? 0) }
        if wrapper.isDirectory {
            return (wrapper.fileWrappers ?? [:]).values.reduce(Int64(0)) { $0 + byteCount(of: $1) }
        }
        return 0
    }

    override func mouseDown(with event: NSEvent) {
        if toggleCheckbox(at: convert(event.locationInWindow, from: nil)) { return }
        super.mouseDown(with: event)
    }

    private func toggleCheckbox(at point: NSPoint) -> Bool {
        guard let lm = layoutManager, let tc = textContainer else { return false }
        let ns = string as NSString
        guard ns.length > 0 else { return false }
        let origin = textContainerOrigin
        let local = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        let glyph = lm.glyphIndex(for: local, in: tc)
        let idx = lm.characterIndexForGlyph(at: glyph)
        guard idx < ns.length else { return false }
        let ch = ns.substring(with: NSRange(location: idx, length: 1))
        guard ch == "☐" || ch == "☑" else { return false }
        let rect = lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: tc)
        guard rect.insetBy(dx: -3, dy: -2).contains(local) else { return false }
        let range = NSRange(location: idx, length: 1)
        let replacement = ch == "☐" ? "☑" : "☐"
        if shouldChangeText(in: range, replacementString: replacement) {
            textStorage?.replaceCharacters(in: range, with: replacement)
            didChangeText()
        }
        return true
    }
}

// MARK: - Координатор одного открытого редактора

final class EditorCoordinator: NSObject, NSTextViewDelegate {
    let noteID: UUID
    weak var textView: NSTextView?
    private var dirty = false
    private var work: DispatchWorkItem?

    init(noteID: UUID) {
        self.noteID = noteID
    }

    func load(into tv: NSTextView) {
        textView = tv
        if let data = Store.shared.body(for: noteID), let attributed = BodyCodec.decode(data), attributed.length > 0 {
            let mutable = NSMutableAttributedString(attributedString: attributed)
            TextTools.normalizeColors(mutable)
            tv.textStorage?.setAttributedString(mutable)
        } else {
            tv.typingAttributes = [.font: TextTools.defaultFont, .foregroundColor: NSColor.labelColor]
        }
        tv.undoManager?.removeAllActions()
        dirty = false
    }

    func textDidChange(_ notification: Notification) {
        dirty = true
        work?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.flush() }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: item)
    }

    func flush() {
        work?.cancel()
        work = nil
        guard dirty, let tv = textView else { return }
        dirty = false
        let attributed = tv.attributedString()
        Store.shared.saveBody(id: noteID, data: BodyCodec.encode(attributed), plain: attributed.string)
    }

    // Двойной щелчок по вложению открывает файл/картинку во внешней программе.
    func textView(_ textView: NSTextView, doubleClickedOn cell: any NSTextAttachmentCellProtocol, in cellFrame: NSRect, at charIndex: Int) {
        guard let storage = textView.textStorage, charIndex < storage.length,
              let attachment = storage.attribute(.attachment, at: charIndex, effectiveRange: nil) as? NSTextAttachment,
              let wrapper = attachment.fileWrapper else { return }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyNotes-open", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let name = wrapper.preferredFilename ?? "attachment"
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let target = dir.appendingPathComponent(name)
            try wrapper.write(to: target, options: .atomic, originalContentsURL: nil)
            NSWorkspace.shared.open(target)
        } catch {
            Dialogs.info(title: "Не удалось открыть вложение", message: error.localizedDescription)
        }
    }

    // Enter в списке продолжает список; Enter в пустом пункте завершает его.
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
        let sel = textView.selectedRange()
        guard sel.length == 0 else { return false }
        let ns = textView.string as NSString
        let pr = ns.paragraphRange(for: sel)
        let line = ns.substring(with: pr)
        for marker in ["•\t", "☐\t", "☑\t"] where line.hasPrefix(marker) {
            let len = marker.utf16.count
            guard sel.location >= pr.location + len else { return false }
            let content = line.trimmingCharacters(in: .newlines)
            if content == marker {
                let r = NSRange(location: pr.location, length: len)
                if textView.shouldChangeText(in: r, replacementString: "") {
                    textView.textStorage?.replaceCharacters(in: r, with: "")
                    textView.textStorage?.removeAttribute(.paragraphStyle, range: NSRange(location: pr.location, length: max(0, pr.length - len)))
                    textView.didChangeText()
                }
            } else {
                let next = marker == "•\t" ? "•\t" : "☐\t"
                textView.insertText("\n" + next, replacementRange: sel)
            }
            return true
        }
        return false
    }
}

// MARK: - SwiftUI-обёртка

struct EditorView: NSViewRepresentable {
    let noteID: UUID

    func makeCoordinator() -> EditorCoordinator {
        EditorCoordinator(noteID: noteID)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)

        let tv = NotesTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]

        tv.isRichText = true
        tv.importsGraphics = true
        tv.allowsImageEditing = true
        tv.allowsUndo = true
        tv.usesFontPanel = true
        tv.usesRuler = false
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isAutomaticLinkDetectionEnabled = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = true
        tv.drawsBackground = false
        tv.font = TextTools.defaultFont
        tv.textContainerInset = NSSize(width: 48, height: 28)
        tv.delegate = context.coordinator

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = tv

        context.coordinator.load(into: tv)
        EditorController.shared.current = context.coordinator
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: EditorCoordinator) {
        coordinator.flush()
        if EditorController.shared.current === coordinator {
            EditorController.shared.current = nil
        }
    }
}

// MARK: - Команды форматирования

enum TextStyle {
    case title, heading, subheading, body
}

final class EditorController {
    static let shared = EditorController()
    weak var current: EditorCoordinator?

    private var tv: NSTextView? { current?.textView }

    func flushCurrent() { current?.flush() }

    private func refocus() {
        if let tv { tv.window?.makeFirstResponder(tv) }
    }

    // Шрифт

    func toggleBold() { toggleTrait(.boldFontMask) }
    func toggleItalic() { toggleTrait(.italicFontMask) }

    private func toggleTrait(_ trait: NSFontTraitMask) {
        guard let tv else { return }
        let fm = NSFontManager.shared
        let range = tv.selectedRange()
        let reference: NSFont
        if range.length > 0, let f = tv.textStorage?.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont {
            reference = f
        } else {
            reference = (tv.typingAttributes[.font] as? NSFont) ?? TextTools.defaultFont
        }
        let has = fm.traits(of: reference).contains(trait)
        applyFont { font in
            has ? fm.convert(font, toNotHaveTrait: trait) : fm.convert(font, toHaveTrait: trait)
        }
        refocus()
    }

    private func applyFont(_ transform: (NSFont) -> NSFont) {
        guard let tv, let storage = tv.textStorage else { return }
        let range = tv.selectedRange()
        if range.length == 0 {
            var attrs = tv.typingAttributes
            attrs[.font] = transform((attrs[.font] as? NSFont) ?? TextTools.defaultFont)
            tv.typingAttributes = attrs
            return
        }
        guard tv.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let base = (value as? NSFont) ?? TextTools.defaultFont
            storage.addAttribute(.font, value: transform(base), range: subrange)
        }
        storage.endEditing()
        tv.didChangeText()
    }

    /// Цвет текста: nil возвращает стандартный (адаптивный) цвет.
    func setTextColor(_ color: NSColor?) {
        guard let tv, let storage = tv.textStorage else { return }
        let range = tv.selectedRange()
        if range.length == 0 {
            var attrs = tv.typingAttributes
            if let color {
                attrs[.foregroundColor] = color
            } else {
                attrs.removeValue(forKey: .foregroundColor)
            }
            tv.typingAttributes = attrs
            return
        }
        guard tv.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        if let color {
            storage.addAttribute(.foregroundColor, value: color, range: range)
        } else {
            storage.removeAttribute(.foregroundColor, range: range)
        }
        storage.endEditing()
        tv.didChangeText()
    }

    func currentTextColor() -> NSColor? {
        guard let tv else { return nil }
        let range = tv.selectedRange()
        if range.length > 0, let storage = tv.textStorage, range.location < storage.length {
            return storage.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
        }
        return tv.typingAttributes[.foregroundColor] as? NSColor
    }

    func showTextColorPanel() {
        ColorPanelHelper.shared.present(initial: currentTextColor()) { [weak self] color in
            self?.setTextColor(color)
        }
    }

    func toggleUnderline() { toggleAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue) }
    func toggleStrikethrough() { toggleAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue) }

    private func toggleAttribute(_ key: NSAttributedString.Key, value: Any) {
        guard let tv, let storage = tv.textStorage else { return }
        let range = tv.selectedRange()
        if range.length == 0 {
            var attrs = tv.typingAttributes
            if attrs[key] != nil { attrs.removeValue(forKey: key) } else { attrs[key] = value }
            tv.typingAttributes = attrs
            refocus()
            return
        }
        let has = storage.attribute(key, at: range.location, effectiveRange: nil) != nil
        guard tv.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        if has { storage.removeAttribute(key, range: range) } else { storage.addAttribute(key, value: value, range: range) }
        storage.endEditing()
        tv.didChangeText()
        refocus()
    }

    // Абзацы

    private func paragraphRanges(in tv: NSTextView) -> [NSRange] {
        let ns = tv.string as NSString
        let selection = tv.selectedRange()
        if ns.length == 0 { return [NSRange(location: 0, length: 0)] }
        let whole = ns.paragraphRange(for: selection)
        var out: [NSRange] = []
        ns.enumerateSubstrings(in: whole, options: [.byParagraphs, .substringNotRequired]) { _, _, enclosing, _ in
            out.append(enclosing)
        }
        return out.isEmpty ? [whole] : out
    }

    func setStyle(_ style: TextStyle) {
        guard let tv, let storage = tv.textStorage else { return }
        let size: CGFloat
        let bold: Bool
        switch style {
        case .title: size = 28; bold = true
        case .heading: size = 22; bold = true
        case .subheading: size = 18; bold = true
        case .body: size = 15; bold = false
        }
        let font = NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
        let ranges = paragraphRanges(in: tv)
        let total = NSRange(location: ranges[0].location, length: NSMaxRange(ranges[ranges.count - 1]) - ranges[0].location)
        var attrs = tv.typingAttributes
        attrs[.font] = font
        tv.typingAttributes = attrs
        if total.length > 0, tv.shouldChangeText(in: total, replacementString: nil) {
            storage.beginEditing()
            storage.addAttribute(.font, value: font, range: total)
            storage.endEditing()
            tv.didChangeText()
        }
        refocus()
    }

    func toggleBullets() { toggleLinePrefix("•\t") }
    func toggleChecklist() { toggleLinePrefix("☐\t") }

    private func toggleLinePrefix(_ prefix: String) {
        guard let tv, let storage = tv.textStorage else { return }
        let ranges = paragraphRanges(in: tv)
        let ns = tv.string as NSString
        let plen = prefix.utf16.count

        func hasPrefix(_ r: NSRange) -> Bool {
            r.length >= plen && ns.substring(with: NSRange(location: r.location, length: plen)) == prefix
        }
        let allHave = ranges.allSatisfy(hasPrefix)
        let total = NSRange(location: ranges[0].location, length: NSMaxRange(ranges[ranges.count - 1]) - ranges[0].location)
        guard tv.shouldChangeText(in: total, replacementString: nil) else { return }

        let style = NSMutableParagraphStyle()
        style.headIndent = 22
        style.firstLineHeadIndent = 0
        style.tabStops = [NSTextTab(textAlignment: .left, location: 22)]
        style.defaultTabInterval = 22

        storage.beginEditing()
        for r in ranges.reversed() {
            if allHave {
                storage.deleteCharacters(in: NSRange(location: r.location, length: plen))
                let current = (storage.string as NSString).paragraphRange(for: NSRange(location: min(r.location, storage.length), length: 0))
                if current.length > 0 { storage.removeAttribute(.paragraphStyle, range: current) }
            } else {
                if hasPrefix(r) { continue }
                var attrs: [NSAttributedString.Key: Any]
                if r.length > 0 && r.location < storage.length {
                    attrs = storage.attributes(at: r.location, effectiveRange: nil)
                } else {
                    attrs = tv.typingAttributes
                }
                attrs.removeValue(forKey: .attachment)
                attrs.removeValue(forKey: .link)
                storage.insert(NSAttributedString(string: prefix, attributes: attrs), at: r.location)
                let current = (storage.string as NSString).paragraphRange(for: NSRange(location: r.location, length: 0))
                storage.addAttribute(.paragraphStyle, value: style, range: current)
            }
        }
        storage.endEditing()
        tv.didChangeText()
        refocus()
    }

    func alignLeft() { tv?.alignLeft(nil); refocus() }
    func alignCenter() { tv?.alignCenter(nil); refocus() }
    func alignRight() { tv?.alignRight(nil); refocus() }

    // Вставка

    func insertLink() {
        guard let tv else { return }
        let range = tv.selectedRange()
        guard let text = Dialogs.prompt(title: "Ссылка", message: "Адрес (например, https://example.com)", ok: "Вставить") else { return }
        let urlString = text.contains("://") ? text : "https://" + text
        guard let url = URL(string: urlString) else { return }
        if range.length > 0 {
            if tv.shouldChangeText(in: range, replacementString: nil) {
                tv.textStorage?.addAttribute(.link, value: url, range: range)
                tv.didChangeText()
            }
        } else {
            let s = NSAttributedString(string: text, attributes: [.link: url, .font: TextTools.defaultFont])
            tv.insertText(s, replacementRange: range)
        }
        refocus()
    }

    func insertImages() {
        guard tv != nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.message = "Выберите изображения"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let attachment = Self.imageAttachment(from: url) {
                insert(attachment, trailingNewline: true)
            }
        }
        refocus()
    }

    /// Окно рисования курсором; готовый рисунок вставляется в заметку как картинка.
    func insertDrawing() {
        guard tv != nil else { return }
        guard let png = DrawingSheet.run() else { refocus(); return }
        let wrapper = FileWrapper(regularFileWithContents: png)
        wrapper.preferredFilename = "Рисунок.png"
        let attachment = NSTextAttachment(fileWrapper: wrapper)
        attachment.image = NSImage(data: png)
        insert(attachment, trailingNewline: true)
        refocus()
    }

    func insertFiles() {
        guard tv != nil else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = "Выберите файлы для вложения в заметку"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let wrapper = try? FileWrapper(url: url, options: .immediate) else { continue }
            wrapper.preferredFilename = url.lastPathComponent
            insert(NSTextAttachment(fileWrapper: wrapper), trailingNewline: true)
        }
        refocus()
    }

    private func insert(_ attachment: NSTextAttachment, trailingNewline: Bool) {
        guard let tv else { return }
        let s = NSMutableAttributedString(attachment: attachment)
        if trailingNewline { s.append(NSAttributedString(string: "\n")) }
        tv.insertText(s, replacementRange: tv.selectedRange())
    }

    private static func imageAttachment(from url: URL) -> NSTextAttachment? {
        guard let image = NSImage(contentsOf: url),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let maxWidth: CGFloat = 720
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
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
        wrapper.preferredFilename = url.deletingPathExtension().lastPathComponent + ".png"
        let attachment = NSTextAttachment(fileWrapper: wrapper)
        attachment.image = NSImage(cgImage: scaled, size: NSSize(width: nw, height: nh))
        return attachment
    }
}

// MARK: - Выбор цвета текста

struct TextColorButton: View {
    let controller: EditorController
    @State private var showPopover = false
    @State private var lastColor: Color?

    private let columns = Array(repeating: GridItem(.fixed(24), spacing: 8), count: 5)

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            VStack(spacing: 1) {
                Text("A").font(.system(size: 13, weight: .bold))
                RoundedRectangle(cornerRadius: 1)
                    .fill(lastColor ?? Color.secondary.opacity(0.5))
                    .frame(width: 14, height: 3)
            }
            .frame(width: 26, height: 24)
        }
        .buttonStyle(.borderless)
        .help("Цвет текста")
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Цвет текста").font(.headline)
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(Palette.presets) { preset in
                        Button {
                            apply(preset.color)
                        } label: {
                            Circle()
                                .fill(Color(nsColor: preset.color))
                                .frame(width: 22, height: 22)
                                .overlay(Circle().stroke(Color.primary.opacity(0.25), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .help(preset.name)
                    }
                }
                Divider()
                Button("Другой цвет…") {
                    showPopover = false
                    controller.showTextColorPanel()
                }
                .buttonStyle(.link)
                Button("Стандартный цвет") {
                    lastColor = nil
                    showPopover = false
                    controller.setTextColor(nil)
                }
                .buttonStyle(.link)
            }
            .padding(14)
            .frame(width: 180)
        }
    }

    private func apply(_ color: NSColor) {
        lastColor = Color(nsColor: color)
        showPopover = false
        controller.setTextColor(color)
    }
}

// MARK: - Панель форматирования

struct FormatBar: View {
    private let c = EditorController.shared

    var body: some View {
        HStack(spacing: 2) {
            Menu {
                Button("Заголовок") { c.setStyle(.title) }
                Button("Подзаголовок") { c.setStyle(.heading) }
                Button("Малый заголовок") { c.setStyle(.subheading) }
                Button("Основной текст") { c.setStyle(.body) }
            } label: {
                Label("Стиль", systemImage: "textformat.size")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.trailing, 6)

            divider
            tool("bold", "Жирный (⌘B)") { c.toggleBold() }
            tool("italic", "Курсив (⌘I)") { c.toggleItalic() }
            tool("underline", "Подчёркнутый (⌘U)") { c.toggleUnderline() }
            tool("strikethrough", "Зачёркнутый (⇧⌘X)") { c.toggleStrikethrough() }
            TextColorButton(controller: c)
            divider
            tool("list.bullet", "Маркированный список (⇧⌘8)") { c.toggleBullets() }
            tool("checklist", "Список задач (⇧⌘7)") { c.toggleChecklist() }
            divider
            tool("text.alignleft", "По левому краю") { c.alignLeft() }
            tool("text.aligncenter", "По центру") { c.alignCenter() }
            tool("text.alignright", "По правому краю") { c.alignRight() }
            divider
            tool("link", "Ссылка (⌘K)") { c.insertLink() }
            tool("photo", "Вставить изображение (⇧⌘I)") { c.insertImages() }
            tool("scribble", "Нарисовать рисунок (⌥⌘D)") { c.insertDrawing() }
            tool("paperclip", "Вложить файл (⇧⌘A)") { c.insertFiles() }
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
    }

    private var divider: some View {
        Divider().frame(height: 16).padding(.horizontal, 4)
    }

    private func tool(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 26, height: 24)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}
