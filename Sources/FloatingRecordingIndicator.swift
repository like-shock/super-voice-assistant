import Cocoa
import Logging
import SharedModels

private let logger = AppLogger.make("FloatingIndicator")

/// Floating panel that shows recording status at the bottom center of the active screen.
/// Non-activating, click-through, always on top. Spokenly-style waveform visualization.
class FloatingRecordingIndicator {
    private var panel: NSPanel?
    private var levelView: RecordingLevelView?
    private let panelWidth: CGFloat = 180
    private let panelHeight: CGFloat = 40

    func show() {
        if panel != nil { return }

        let view = RecordingLevelView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
        levelView = view

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        panel.contentView = view

        positionPanel(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        // Fade in
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 1
        }

        self.panel = panel
        logger.info("Recording indicator shown")
    }

    func hide() {
        guard let panel = panel else { return }

        // Fade out then remove
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel?.orderOut(nil)
            self?.panel = nil
            self?.levelView = nil
        })
        logger.info("Recording indicator hidden")
    }

    func updateLevel(db: Float) {
        levelView?.updateLevel(db: db)
    }

    func showProcessing() {
        levelView?.showProcessing()
    }

    private func positionPanel(_ panel: NSPanel) {
        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens[0]

        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - panelWidth / 2
        let y = screenFrame.origin.y + 48
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - Waveform Recording View

class RecordingLevelView: NSView {
    private var isProcessing = false
    private var processingDotCount = 0
    private var processingTimer: Timer?

    // Waveform: circular buffer of recent audio levels
    private let barCount = 24
    private var levelHistory: [Float] = []
    private var currentLevel: Float = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        levelHistory = Array(repeating: 0, count: barCount)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let rect = bounds
        let cornerRadius: CGFloat = rect.height / 2

        // Background: dark rounded pill
        let bgPath = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        NSColor(white: 0.1, alpha: 0.88).setFill()
        bgPath.fill()

        if isProcessing {
            drawProcessing(in: rect)
        } else {
            drawWaveform(in: rect)
        }
    }

    private func drawWaveform(in rect: NSRect) {
        let leftPadding: CGFloat = 14
        let rightPadding: CGFloat = 14
        let dotRadius: CGFloat = 5
        let topBottomPad: CGFloat = 10

        // Red recording dot (pulsing)
        let dotY = rect.midY - dotRadius
        let dotRect = NSRect(x: leftPadding, y: dotY, width: dotRadius * 2, height: dotRadius * 2)
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: dotRect).fill()

        // Waveform bars
        let waveStartX = dotRect.maxX + 12
        let waveEndX = rect.width - rightPadding
        let waveWidth = waveEndX - waveStartX
        let maxBarHeight = rect.height - topBottomPad * 2
        let minBarHeight: CGFloat = 2
        let barWidth: CGFloat = 3
        let barSpacing: CGFloat = max(1, (waveWidth - CGFloat(barCount) * barWidth) / CGFloat(barCount - 1))

        for i in 0..<barCount {
            let level = CGFloat(levelHistory[i])
            let barHeight = max(minBarHeight, level * maxBarHeight)
            let x = waveStartX + CGFloat(i) * (barWidth + barSpacing)
            let y = rect.midY - barHeight / 2

            let barRect = NSRect(x: x, y: y, width: barWidth, height: barHeight)
            let barPath = NSBezierPath(roundedRect: barRect, xRadius: barWidth / 2, yRadius: barWidth / 2)

            // Color: white with opacity based on level
            let alpha = 0.4 + level * 0.6
            NSColor.white.withAlphaComponent(alpha).setFill()
            barPath.fill()
        }
    }

    private func drawProcessing(in rect: NSRect) {
        let padding: CGFloat = 14

        // Gear icon
        let gearAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.white
        ]
        let gear = NSAttributedString(string: "⚙", attributes: gearAttrs)
        let gearY = rect.midY - gear.size().height / 2
        gear.draw(at: NSPoint(x: padding, y: gearY))

        // "Processing..." label
        let dots = String(repeating: ".", count: processingDotCount)
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let label = NSAttributedString(string: "Processing\(dots)", attributes: labelAttrs)
        let labelX = padding + gear.size().width + 6
        let labelY = rect.midY - label.size().height / 2
        label.draw(at: NSPoint(x: labelX, y: labelY))
    }

    func updateLevel(db: Float) {
        isProcessing = false
        stopProcessingTimer()

        // Convert dB to 0-1 range
        currentLevel = max(0, min(1, (db + 55) / 35))

        // Shift history left, push new level
        levelHistory.removeFirst()
        levelHistory.append(currentLevel)

        needsDisplay = true
    }

    func showProcessing() {
        isProcessing = true
        levelHistory = Array(repeating: 0, count: barCount)
        processingDotCount = 0
        needsDisplay = true

        stopProcessingTimer()
        processingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.processingDotCount = (self.processingDotCount + 1) % 4
            self.needsDisplay = true
        }
    }

    private func stopProcessingTimer() {
        processingTimer?.invalidate()
        processingTimer = nil
    }
}
