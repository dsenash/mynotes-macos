import AppKit

// Окно для рисования курсором: перо, цвет, толщина, ластик, отмена, очистка.
// Результат — PNG, который вставляется в заметку как картинка.

private struct Stroke {
    var points: [NSPoint]
    var color: NSColor
    var width: CGFloat
}

final class CanvasView: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    fileprivate var strokes: [Stroke] = []
    private var current: Stroke?

    var penColor: NSColor = .black
    var penWidth: CGFloat = 3
    var eraser = false

    var isEmpty: Bool { strokes.isEmpty }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        for stroke in strokes { paint(stroke) }
        if let current { paint(current) }
    }

    private func paint(_ stroke: Stroke) {
        guard let first = stroke.points.first else { return }
        stroke.color.setStroke()
        stroke.color.setFill()
        if stroke.points.count == 1 {
            let r = NSRect(x: first.x - stroke.width / 2, y: first.y - stroke.width / 2,
                           width: stroke.width, height: stroke.width)
            NSBezierPath(ovalIn: r).fill()
            return
        }
        let path = NSBezierPath()
        path.lineWidth = stroke.width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: first)
        for point in stroke.points.dropFirst() { path.line(to: point) }
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        current = Stroke(
            points: [point],
            color: eraser ? .white : penColor,
            width: eraser ? max(penWidth * 3, 10) : penWidth
        )
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard current != nil else { return }
        current?.points.append(convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let finished = current { strokes.append(finished) }
        current = nil
        needsDisplay = true
    }

    func undo() {
        guard !strokes.isEmpty else { return }
        strokes.removeLast()
        needsDisplay = true
    }

    func clear() {
        strokes.removeAll()
        current = nil
        needsDisplay = true
    }

    func exportPNG() -> Data? {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}

private final class DrawingController: NSObject, NSWindowDelegate {
    let window: NSWindow
    let canvas = CanvasView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
    private let colorWell = NSColorWell()
    private let widthSlider = NSSlider(value: 3, minValue: 1, maxValue: 24, target: nil, action: nil)
    private let eraserButton = NSButton(checkboxWithTitle: "Ластик", target: nil, action: nil)
    var result: Data?

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = "Рисунок"
        window.isReleasedWhenClosed = false
        window.delegate = self
        build()
    }

    private func build() {
        canvas.wantsLayer = true
        canvas.layer?.borderWidth = 1
        canvas.layer?.borderColor = NSColor.separatorColor.cgColor
        canvas.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            canvas.widthAnchor.constraint(equalToConstant: 640),
            canvas.heightAnchor.constraint(equalToConstant: 400)
        ])

        colorWell.color = .black
        colorWell.target = self
        colorWell.action = #selector(colorChanged)
        colorWell.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            colorWell.widthAnchor.constraint(equalToConstant: 44),
            colorWell.heightAnchor.constraint(equalToConstant: 24)
        ])

        widthSlider.target = self
        widthSlider.action = #selector(widthChanged)
        widthSlider.translatesAutoresizingMaskIntoConstraints = false
        widthSlider.widthAnchor.constraint(equalToConstant: 140).isActive = true

        eraserButton.target = self
        eraserButton.action = #selector(eraserChanged)

        let undo = NSButton(title: "Отменить штрих", target: self, action: #selector(undoPressed))
        let clear = NSButton(title: "Очистить", target: self, action: #selector(clearPressed))

        let tools = NSStackView(views: [
            NSTextField(labelWithString: "Цвет:"), colorWell,
            NSTextField(labelWithString: "Толщина:"), widthSlider,
            eraserButton, undo, clear
        ])
        tools.orientation = .horizontal
        tools.spacing = 10
        tools.alignment = .centerY

        let insert = NSButton(title: "Вставить в заметку", target: self, action: #selector(insertPressed))
        insert.keyEquivalent = "\r"
        let cancel = NSButton(title: "Отмена", target: self, action: #selector(cancelPressed))
        cancel.keyEquivalent = "\u{1b}"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancel, insert])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let stack = NSStackView(views: [tools, canvas, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        window.contentView = content
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            buttons.widthAnchor.constraint(equalTo: canvas.widthAnchor)
        ])
        content.layoutSubtreeIfNeeded()
        window.setContentSize(content.fittingSize)
    }

    func run() -> Data? {
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: window)
        window.orderOut(nil)
        return result
    }

    @objc private func colorChanged() {
        canvas.penColor = colorWell.color
        canvas.eraser = false
        eraserButton.state = .off
    }

    @objc private func widthChanged() { canvas.penWidth = CGFloat(widthSlider.doubleValue) }
    @objc private func eraserChanged() { canvas.eraser = eraserButton.state == .on }
    @objc private func undoPressed() { canvas.undo() }
    @objc private func clearPressed() { canvas.clear() }

    @objc private func insertPressed() {
        if !canvas.isEmpty { result = canvas.exportPNG() }
        NSColorPanel.shared.orderOut(nil)
        NSApp.stopModal()
    }

    @objc private func cancelPressed() {
        NSColorPanel.shared.orderOut(nil)
        NSApp.stopModal()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.stopModal()
    }
}

enum DrawingSheet {
    /// Открывает окно рисования и возвращает PNG или nil, если пользователь отменил или ничего не нарисовал.
    static func run() -> Data? {
        DrawingController().run()
    }
}
