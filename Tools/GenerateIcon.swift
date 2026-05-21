import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resources = root.appendingPathComponent("Resources", isDirectory: true)
let iconset = resources.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let specs: [(String, CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

func writePNG(size: CGFloat, url: URL) throws {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    NSGraphicsContext.current?.imageInterpolation = .high

    let radius = size * 0.225
    let bg = NSBezierPath(roundedRect: rect.insetBy(dx: size * 0.035, dy: size * 0.035),
                          xRadius: radius,
                          yRadius: radius)
    NSColor(calibratedRed: 0.06, green: 0.075, blue: 0.08, alpha: 1).setFill()
    bg.fill()

    let inner = rect.insetBy(dx: size * 0.15, dy: size * 0.2)
    let capsule = NSBezierPath(roundedRect: inner,
                               xRadius: inner.height / 2,
                               yRadius: inner.height / 2)
    NSColor(calibratedRed: 0.86, green: 0.96, blue: 0.91, alpha: 1).setFill()
    capsule.fill()

    let weights: [CGFloat] = [0.52, 0.82, 1.0, 0.76, 0.56]
    let barWidth = size * 0.045
    let gap = size * 0.038
    let totalWidth = barWidth * CGFloat(weights.count) + gap * CGFloat(weights.count - 1)
    let startX = rect.midX - totalWidth / 2
    let maxHeight = inner.height * 0.6
    for (index, weight) in weights.enumerated() {
        let height = max(size * 0.08, maxHeight * weight)
        let x = startX + CGFloat(index) * (barWidth + gap)
        let y = rect.midY - height / 2
        let path = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: barWidth, height: height),
                                xRadius: barWidth / 2,
                                yRadius: barWidth / 2)
        NSColor(calibratedRed: 0.08, green: 0.13, blue: 0.13, alpha: 1).setFill()
        path.fill()
    }

    let shine = NSBezierPath(roundedRect: NSRect(x: size * 0.22, y: size * 0.7, width: size * 0.36, height: size * 0.035),
                             xRadius: size * 0.02,
                             yRadius: size * 0.02)
    NSColor(calibratedRed: 0.94, green: 0.99, blue: 0.96, alpha: 0.42).setFill()
    shine.fill()

    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "VoiceTypeIcon", code: 1)
    }
    try data.write(to: url)
}

for (name, size) in specs {
    try writePNG(size: size, url: iconset.appendingPathComponent(name))
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = [
    "-c", "icns",
    iconset.path,
    "-o", resources.appendingPathComponent("AppIcon.icns").path
]
try process.run()
process.waitUntilExit()
if process.terminationStatus != 0 {
    throw NSError(domain: "VoiceTypeIcon", code: Int(process.terminationStatus))
}
