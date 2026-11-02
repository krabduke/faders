import AppKit

extension NSImage {
    /// The icon's most characteristic colour: an average weighted towards saturated,
    /// bright pixels, so Spotify comes out green rather than a muddy grey.
    var dominantColor: NSColor {
        let size = 24
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return .controlAccentColor }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()

        var red = 0.0, green = 0.0, blue = 0.0, total = 0.0
        for x in 0..<size {
            for y in 0..<size {
                guard let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.5 else { continue }
                let saturation = color.saturationComponent, brightness = color.brightnessComponent
                let weight = saturation * saturation * brightness
                red += color.redComponent * weight
                green += color.greenComponent * weight
                blue += color.blueComponent * weight
                total += weight
            }
        }
        // Mostly grey or white icons (Terminal, Finder-ish) keep the system accent colour.
        guard total > 3 else { return .controlAccentColor }
        let average = NSColor(deviceRed: red / total, green: green / total, blue: blue / total, alpha: 1)
        return NSColor(deviceHue: average.hueComponent,
                       saturation: max(average.saturationComponent, 0.55),
                       brightness: min(max(average.brightnessComponent, 0.6), 0.9), alpha: 1)
    }
}
