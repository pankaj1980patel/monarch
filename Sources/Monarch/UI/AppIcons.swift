import AppKit

/// App icons for the switcher and the overview, one shared cache.
///
/// An app's icon is a multi-size image (up to 1024 px); drawing it picks a representation on
/// every draw and keeps the large ones in memory. This renders each icon once into a small
/// bitmap at the size it's actually drawn (2× for Retina) and reuses that. Entries are dropped
/// when the app quits (the engine calls `forget`), so a reused process id never shows an old icon.
@MainActor
enum AppIcons {
    private struct Key: Hashable { let pid: pid_t; let points: Int; let shadow: Bool }
    private static var cache: [Key: NSImage] = [:]

    /// Room around a shadowed icon for the shadow (at the switcher's full icon size).
    static let shadowMargin: CGFloat = 14

    /// `shadow`: the switcher's soft drop shadow drawn into the bitmap once (the image is then
    /// `points + 2 × shadowMargin` wide, icon centred), so drawing a tile is a plain copy
    /// instead of a CPU-blurred shadow per tile per draw.
    static func icon(_ pid: pid_t, points: CGFloat, shadow: Bool = false) -> NSImage? {
        let key = Key(pid: pid, points: Int(points.rounded()), shadow: shadow)
        if let i = cache[key] { return i }
        guard let src = NSRunningApplication(processIdentifier: pid)?.icon else { return nil }
        let m = shadow ? Int(shadowMargin) : 0
        let side = key.points + 2 * m
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side * 2, pixelsHigh: side * 2, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return src }
        rep.size = NSSize(width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        if shadow {
            let s = NSShadow()
            s.shadowBlurRadius = 10
            s.shadowOffset = NSSize(width: 0, height: -4)
            s.shadowColor = NSColor(white: 0, alpha: 0.4)
            s.set()
        }
        src.draw(in: NSRect(x: m, y: m, width: key.points, height: key.points))
        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        cache[key] = img
        return img
    }

    /// Renders an app's icons ahead of time (when it's first tracked), so the first ⌘Tab or
    /// overview that shows it doesn't.
    static func prewarm(_ pid: pid_t) {
        _ = icon(pid, points: 84, shadow: true)
        _ = icon(pid, points: 28)
    }

    static func forget(_ pid: pid_t) {
        cache = cache.filter { $0.key.pid != pid }
    }
}
