/*
Copyright (C) 2026 Afcoo.
*/

import AppKit

final class MenuBarStatusItemView: NSView {
    enum WidthBehavior {
        case stable
        case contentFitting
    }

    private static let horizontalChromeWidth: CGFloat = 43
    private static let stableWidth: CGFloat = {
        let font = NSFont.menuFont(ofSize: 0)
        let referenceUSBID = "FFFF:FFFF"
        let referenceTitles = [
            String(localized: "USB: \(referenceUSBID)"),
            String(localized: "USB: Not attached"),
            String(localized: "WireGuard: Provider connected"),
        ]
        let titleWidth = referenceTitles
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        return ceil(titleWidth + horizontalChromeWidth)
    }()

    private let dotView: StatusDotView
    private let titleLabel: NSTextField
    private let widthBehavior: WidthBehavior

    init(
        title: String,
        dotColor: NSColor,
        widthBehavior: WidthBehavior = .stable
    ) {
        let font = NSFont.menuFont(ofSize: 0)
        self.dotView = StatusDotView(color: dotColor)
        self.titleLabel = NSTextField(labelWithString: title)
        self.widthBehavior = widthBehavior
        super.init(frame: NSRect(
            x: 0,
            y: 0,
            width: Self.width(for: title, font: font, behavior: widthBehavior),
            height: 22
        ))
        autoresizingMask = [.width]

        dotView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = font
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1

        addSubview(dotView)
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            dotView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            dotView.centerYAnchor.constraint(equalTo: centerYAnchor),
            dotView.widthAnchor.constraint(equalToConstant: 18),
            dotView.heightAnchor.constraint(equalToConstant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: dotView.trailingAnchor, constant: 2),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
        ])
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: Self.width(
                for: titleLabel.stringValue,
                font: titleLabel.font ?? NSFont.menuFont(ofSize: 0),
                behavior: widthBehavior
            ),
            height: 22
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(title: String, dotColor: NSColor) {
        if titleLabel.stringValue != title {
            titleLabel.stringValue = title
            invalidateIntrinsicContentSize()
        }
        dotView.update(color: dotColor)
    }

    private static func width(
        for title: String,
        font: NSFont,
        behavior: WidthBehavior
    ) -> CGFloat {
        switch behavior {
        case .stable:
            return stableWidth
        case .contentFitting:
            let titleWidth = (title as NSString).size(
                withAttributes: [.font: font]
            ).width
            return ceil(titleWidth + horizontalChromeWidth)
        }
    }
}

private final class StatusDotView: NSView {
    private var dotColor: NSColor

    init(color: NSColor) {
        self.dotColor = color
        super.init(frame: .zero)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current?.cgContext else {
            return
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
            return
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(color: NSColor) {
        dotColor = color
        needsDisplay = true
    }
}
