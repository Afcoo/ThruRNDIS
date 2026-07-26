/*
Copyright (C) 2026 Afcoo.
*/

import AppKit

enum MenuBarStatusDotImageFactory {
    static let size = NSSize(width: 18, height: 18)

    static func makeImage(color dotColor: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { bounds in
            guard let context = NSGraphicsContext.current?.cgContext else {
                return false
            }

            let color = dotColor.usingColorSpace(.deviceRGB) ?? dotColor
            let colors = [
                color.withAlphaComponent(0.64).cgColor,
                color.withAlphaComponent(0.28).cgColor,
                color.withAlphaComponent(0).cgColor,
            ] as CFArray
            let locations: [CGFloat] = [0, 0.5, 1]

            guard let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors,
                locations: locations
            ) else {
                return false
            }

            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            context.drawRadialGradient(
                gradient,
                startCenter: center,
                startRadius: 0,
                endCenter: center,
                endRadius: 9,
                options: []
            )
            context.setFillColor(color.cgColor)
            context.fillEllipse(in: CGRect(
                x: center.x - 4,
                y: center.y - 4,
                width: 8,
                height: 8
            ))
            return true
        }
        image.isTemplate = false
        return image
    }
}
