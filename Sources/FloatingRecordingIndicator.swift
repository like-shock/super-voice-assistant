import Cocoa
import Logging
import SharedModels

private let logger = AppLogger.make("FloatingIndicator")

/// Floating panel that shows recording status at the bottom center of the active screen.
/// Non-activating, click-through, always on top.
class FloatingRecordingIndicator {
    private var panel: NSPanel?
    private var levelView: RecordingLevelView?
    private let panelWidth: CGFloat = 200
    private let panelHeight: CGFloat = 36

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
        // Place at bottom center of the screen containing the mouse cursor
        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens[0]

        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - panelWidth / 2
        let y = screenFrame.origin.y + 48  // 48pt above bottom
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - Custom NSView for recording level visualization

class RecordingLevelView: NSView {
    private var normalizedLevel: Float = 0
    private var isProcessing = false
    private var processingDotCount = 0
    private var processingTimer: Timer?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let rect = bounds
        let cornerRadius: CGFloat = 18

        // Background: dark rounded pill
        let bgPath = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        NSColor(white: 0.1, alpha: 0.85).setFill()
        bgPath.fill()

        if isProcessing {
            drawProcessing(in: rect)
        } else {
            drawRecordingLevel(in: rect)
        }
    }

    private func drawRecordingLevel(in rect: NSRect) {
        let padding: CGFloat = 12
        let dotRadius: CGFloat = 5

        // Red recording dot
        let dotRect = NSRect(
            x: padding,
            y: rect.midY - dotRadius,
            width: dotRadius * 2,
            height: dotRadius * 2
        )
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: dotRect).fill()

        // "REC" label
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let label = NSAttributedString(string: "REC", attributes: labelAttrs)
        let labelX = dotRect.maxX + 6
        let labelY = rect.midY - label.size().height / 2
        label.draw(at: NSPoint(x: labelX, y: labelY))

        // Level bar
        let barX = labelX + label.size().width + 10
        let barWidth = rect.width - barX - padding
        let barHeight: CGFloat = 6
        let barY = rect.midY - barHeight / 2

        // Bar background
        let barBgRect = NSRect(x: barX, y: barY, width: barWidth, height: barHeight)
        let barBgPath = NSBezierPath(roundedRect: barBgRect, xRadius: 3, yRadius: 3)
        NSColor(white: 0.3, alpha: 1).setFill()
        barBgPath.fill()

        // Bar fill
        let fillWidth = CGFloat(normalizedLevel) * barWidth
        if fillWidth > 0 {
            let fillRect = NSRect(x: barX, y: barY, width: fillWidth, height: barHeight)
            let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: 3, yRadius: 3)

            // Color gradient: green → yellow → red
            let color: NSColor
            if normalizedLevel < 0.5 {
                color = NSColor.systemGreen
            } else if normalizedLevel < 0.8 {
                color = NSColor.systemYellow
            } else {
                color = NSColor.systemRed
            }
            color.setFill()
            fillPath.fill()
        }
    }

    private func drawProcessing(in rect: NSRect) {
        let padding: CGFloat = 12

        // Gear icon
        let gearAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
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
        // Convert dB to 0-1 range (-55dB to -20dB for normal speech)
        normalizedLevel = max(0, min(1, (db + 55) / 35))
        needsDisplay = true
    }

    func showProcessing() {
        isProcessing = true
        normalizedLevel = 0
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
