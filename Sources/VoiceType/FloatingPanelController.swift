import AppKit
import QuartzCore

final class FloatingPanelController {
    private let panel: NSPanel
    private let container = NSVisualEffectView()
    private let waveformView = WaveformView()
    private let label = NSTextField(labelWithString: "")
    private var widthConstraint: NSLayoutConstraint!
    private var isVisible = false

    private let baseHeight: CGFloat = 56
    private let minTextWidth: CGFloat = 160
    private let maxTextWidth: CGFloat = 560
    private let fixedChromeWidth: CGFloat = 84

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 56),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true

        configureViews()
    }

    func show(text: String = "Listening...") {
        VoiceTypeLogger.log("hud.show text=\(text)")
        update(text: text)
        update(level: 0.04)
        positionPanel()
        if !isVisible {
            isVisible = true
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            runEntryAnimation()
        }
    }

    func update(text: String) {
        let clean = text.trimmingCharacters(in: .newlines)
        label.stringValue = clean.isEmpty ? "Listening..." : clean
        let textWidth = measuredTextWidth(for: label.stringValue)
        let panelWidth = fixedChromeWidth + textWidth

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            widthConstraint.animator().constant = textWidth
            panel.animator().setFrame(frame(width: panelWidth), display: true)
        }
    }

    func updateStatus(_ status: String) {
        VoiceTypeLogger.log("hud.status text=\(status)")
        update(text: status)
    }

    func update(level: Float) {
        waveformView.setRMS(level)
    }

    func hide() {
        guard isVisible else { return }
        VoiceTypeLogger.log("hud.hide")
        isVisible = false
        runExitAnimation()
    }

    private func configureViews() {
        container.material = .hudWindow
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = baseHeight / 2
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 56))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = root

        container.translatesAutoresizingMaskIntoConstraints = false
        waveformView.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false

        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = NSColor(calibratedWhite: 0.96, alpha: 1)
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1

        root.addSubview(container)
        container.addSubview(waveformView)
        container.addSubview(label)

        widthConstraint = label.widthAnchor.constraint(equalToConstant: minTextWidth)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.topAnchor.constraint(equalTo: root.topAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            waveformView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            waveformView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            waveformView.widthAnchor.constraint(equalToConstant: 44),
            waveformView.heightAnchor.constraint(equalToConstant: 32),

            label.leadingAnchor.constraint(equalTo: waveformView.trailingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            widthConstraint
        ])
    }

    private func measuredTextWidth(for text: String) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: label.font as Any]
        let width = (text as NSString).size(withAttributes: attributes).width + 6
        return min(max(width, minTextWidth), maxTextWidth)
    }

    private func positionPanel() {
        panel.setFrame(frame(width: panel.frame.width), display: false)
    }

    private func frame(width: CGFloat) -> NSRect {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let x = visibleFrame.midX - width / 2
        let y = visibleFrame.minY + 72
        return NSRect(x: x, y: y, width: width, height: baseHeight)
    }

    private func runEntryAnimation() {
        container.layer?.removeAllAnimations()
        container.layer?.setAffineTransform(CGAffineTransform(scaleX: 0.92, y: 0.92))

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        let spring = CASpringAnimation(keyPath: "transform.scale")
        spring.fromValue = 0.9
        spring.toValue = 1.0
        spring.mass = 0.85
        spring.stiffness = 155
        spring.damping = 19
        spring.initialVelocity = 0.7
        spring.duration = 0.35
        container.layer?.add(spring, forKey: "entrySpring")
        container.layer?.setAffineTransform(.identity)
    }

    private func runExitAnimation() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 0
        } completionHandler: {
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
            self.container.layer?.setAffineTransform(.identity)
        }

        let shrink = CABasicAnimation(keyPath: "transform.scale")
        shrink.fromValue = 1.0
        shrink.toValue = 0.96
        shrink.duration = 0.22
        shrink.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        container.layer?.add(shrink, forKey: "exitScale")
    }
}

final class WaveformView: NSView {
    private let weights: [CGFloat] = [0.5, 0.8, 1.0, 0.75, 0.55]
    private var envelope: CGFloat = 0.04
    private var jitters: [CGFloat] = Array(repeating: 1, count: 5)

    override var isFlipped: Bool { true }

    func setRMS(_ rms: Float) {
        let clamped = max(0, min(CGFloat(rms) * 3.8, 1))
        if clamped > envelope {
            envelope += (clamped - envelope) * 0.40
        } else {
            envelope += (clamped - envelope) * 0.15
        }
        jitters = weights.map { _ in CGFloat.random(in: 0.96...1.04) }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor(calibratedRed: 0.78, green: 1.0, blue: 0.86, alpha: 1).setFill()

        let barWidth: CGFloat = 5
        let gap: CGFloat = 4
        let totalWidth = CGFloat(weights.count) * barWidth + CGFloat(weights.count - 1) * gap
        let startX = bounds.midX - totalWidth / 2
        let minHeight: CGFloat = 7
        let maxHeight = bounds.height - 2

        for index in weights.indices {
            let weighted = envelope * weights[index] * jitters[index]
            let height = min(maxHeight, max(minHeight, minHeight + weighted * (maxHeight - minHeight)))
            let rect = NSRect(
                x: startX + CGFloat(index) * (barWidth + gap),
                y: bounds.midY - height / 2,
                width: barWidth,
                height: height
            )
            let path = NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2)
            path.fill()
        }
    }
}
