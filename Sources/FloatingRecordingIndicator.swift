import Cocoa
import Logging
import SharedModels

private let logger = AppLogger.make("FloatingIndicator")

/// Floating panel that shows recording status at the bottom center of the active screen.
/// Two-line Spokenly-style layout:
///   Line 1: [App Icon] [App Name]
///   Line 2: [● Waveform bars...]
class FloatingRecordingIndicator {
    private var panel: NSPanel?
    private var levelView: RecordingLevelView?
    private let panelWidth: CGFloat = 200
    private let panelHeight: CGFloat = 64

    func show() {
        if panel != nil { return }

        let frontApp = NSWorkspace.shared.frontmostApplication
        let appName = frontApp?.localizedName ?? ""
        let appIcon = frontApp?.icon

        let view = RecordingLevelView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
        view.configure(appName: appName, appIcon: appIcon)
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

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 1
        }

        self.panel = panel
        logger.info("Recording indicator shown for app: \(appName)")
    }

    func hide() {
        guard let panel = panel else { return }

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

// MARK: - Two-line Waveform Recording View

class RecordingLevelView: NSView {
    private var isProcessing = false
    private var processingDotCount = 0
    private var processingTimer: Timer?

    private let barCount = 28
    private var levelHistory: [Float] = []
    private var currentLevel: Float = 0

    private var appName: String = ""
    private var appIcon: NSImage?

    override init(frame: NSRect) {
        super.init(frame: frame)
        levelHistory = Array(repeating: 0, count: barCount)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(appName: String, appIcon: NSImage?) {
        self.appName = appName
        if let icon = appIcon {
            let resized = NSImage(size: NSSize(width: 16, height: 16))
            resized.lockFocus()
            icon.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16))
            resized.unlockFocus()
            self.appIcon = resized
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let rect = bounds
        let cornerRadius: CGFloat = 14

        // Background
        let bgPath = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        NSColor(white: 0.1, alpha: 0.88).setFill()
        bgPath.fill()

        let horizontalPad: CGFloat = 14
        // NSView origin is bottom-left: top row is higher Y, bottom row is lower Y
        let topRowY = rect.height * 0.70    // upper row center (app info)
        let bottomRowY = rect.height * 0.30 // lower row center (waveform)

        // --- Line 1: App icon + App name ---
        drawAppInfo(in: rect, centerY: topRowY, horizontalPad: horizontalPad)

        // --- Line 2: Recording dot + Waveform / Processing ---
        if isProcessing {
            drawProcessingRow(in: rect, centerY: bottomRowY, horizontalPad: horizontalPad)
        } else {
            drawWaveformRow(in: rect, centerY: bottomRowY, horizontalPad: horizontalPad)
        }
    }

    private func drawAppInfo(in rect: NSRect, centerY: CGFloat, horizontalPad: CGFloat) {
        var cursorX = horizontalPad

        // App icon
        if let icon = appIcon {
            let iconY = centerY - 8
            icon.draw(in: NSRect(x: cursorX, y: iconY, width: 16, height: 16))
            cursorX += 22
        }

        // App name
        if !appName.isEmpty {
            let nameAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.white.withAlphaComponent(0.9)
            ]
            let nameStr = NSAttributedString(string: appName, attributes: nameAttrs)
            let nameY = centerY - nameStr.size().height / 2
            nameStr.draw(at: NSPoint(x: cursorX, y: nameY))
        }
    }

    private func drawWaveformRow(in rect: NSRect, centerY: CGFloat, horizontalPad: CGFloat) {
        let dotRadius: CGFloat = 5

        // Red recording dot
        let dotX = horizontalPad
        let dotRect = NSRect(x: dotX, y: centerY - dotRadius, width: dotRadius * 2, height: dotRadius * 2)
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: dotRect).fill()

        // Waveform bars
        let waveStartX = dotRect.maxX + 8
        let waveEndX = rect.width - horizontalPad
        let waveWidth = waveEndX - waveStartX
        guard waveWidth > 0 else { return }

        let maxBarHeight: CGFloat = 22
        let minBarHeight: CGFloat = 3
        let barWidth: CGFloat = 3
        let barSpacing = max(1, (waveWidth - CGFloat(barCount) * barWidth) / CGFloat(barCount - 1))

        for i in 0..<barCount {
            let level = CGFloat(levelHistory[i])
            let barHeight = max(minBarHeight, level * maxBarHeight)
            let x = waveStartX + CGFloat(i) * (barWidth + barSpacing)
            guard x + barWidth <= waveEndX else { break }
            let y = centerY - barHeight / 2

            let barRect = NSRect(x: x, y: y, width: barWidth, height: barHeight)
            let barPath = NSBezierPath(roundedRect: barRect, xRadius: barWidth / 2, yRadius: barWidth / 2)

            let alpha = 0.4 + level * 0.6
            NSColor.white.withAlphaComponent(alpha).setFill()
            barPath.fill()
        }
    }

    private func drawProcessingRow(in rect: NSRect, centerY: CGFloat, horizontalPad: CGFloat) {
        let gearAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.white
        ]
        let gear = NSAttributedString(string: "⚙", attributes: gearAttrs)
        let gearY = centerY - gear.size().height / 2
        gear.draw(at: NSPoint(x: horizontalPad, y: gearY))

        let dots = String(repeating: ".", count: processingDotCount)
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let label = NSAttributedString(string: "Processing\(dots)", attributes: labelAttrs)
        let labelX = horizontalPad + gear.size().width + 4
        let labelY = centerY - label.size().height / 2
        label.draw(at: NSPoint(x: labelX, y: labelY))
    }

    func updateLevel(db: Float) {
        isProcessing = false
        stopProcessingTimer()
        currentLevel = max(0, min(1, (db + 55) / 35))
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
