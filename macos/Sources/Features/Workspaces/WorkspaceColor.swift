import AppKit

/// A Workspace color: one of the Tab palette's colors, or one the user mixes on the
/// customizer's pad. It fills the Workspace's dot and washes the vertical tab bar while the
/// Workspace is shown.
enum WorkspaceColor: Hashable {
    case palette(TerminalTabColor)
    /// A mixed color, at `customBrightness`.
    case custom(hue: Double, saturation: Double)

    static let none = WorkspaceColor.palette(.none)

    /// Every mixed color's brightness, so a wash stays as vivid as the palette's wherever
    /// the pad is picked.
    static let customBrightness = 0.9

    var displayColor: NSColor? {
        switch self {
        case .palette(let color):
            color.displayColor
        case .custom(let hue, let saturation):
            NSColor(colorSpace: .sRGB, hue: hue, saturation: saturation, brightness: Self.customBrightness, alpha: 1)
        }
    }
}

extension WorkspaceColor: Codable {
    // A palette color encodes as its Tab palette index, the way every Workspace color was
    // saved before mixed ones, so those saves still decode. A mixed color encodes its hue
    // and saturation.
    private enum CodingKeys: String, CodingKey {
        case hue
        case saturation
    }

    init(from decoder: Decoder) throws {
        if let color = try? decoder.singleValueContainer().decode(TerminalTabColor.self) {
            self = .palette(color)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = .custom(
            hue: try container.decode(Double.self, forKey: .hue),
            saturation: try container.decode(Double.self, forKey: .saturation))
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .palette(let color):
            var container = encoder.singleValueContainer()
            try container.encode(color)
        case .custom(let hue, let saturation):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(hue, forKey: .hue)
            try container.encode(saturation, forKey: .saturation)
        }
    }
}
