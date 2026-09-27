import SwiftUI

/// Customize Workspace…: the popover where a Workspace gets its name, its color, and its
/// terminal theme, the way Arc's theme editor dresses a Space. Every change applies as it's
/// made, so the bar and the terminal show it while the popover is open.
struct WorkspaceCustomizer: View {
    /// Follows the Workspace while the popover is open.
    @ObservedObject var store: WorkspaceStore
    let id: WorkspaceStore.Workspace.ID

    @State private var name = ""

    var body: some View {
        if let workspace = store.workspaces.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 14) {
                TextField("Workspace Name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 8)
                    .frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.06)))
                    .onAppear { name = workspace.name }
                    // A blank name shows the original one, as a blank rename does.
                    .onChange(of: name) { store.rename(id, to: $0) }

                section("Color") {
                    ColorChoices(color: workspace.color) { store.setColor($0, of: id) }
                }

                section("Theme") {
                    ThemePicker(theme: workspace.theme) { store.setTheme($0, of: id) }
                }
            }
            .padding(14)
            .frame(width: 290)
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }
}

// MARK: - Color

/// None and the Tab palette as swatches, then a custom swatch that opens the pad.
private struct ColorChoices: View {
    let color: WorkspaceColor
    let set: (WorkspaceColor) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 2) {
                ForEach(TerminalTabColor.allCases, id: \.self) { palette in
                    Swatch(isSelected: color == .palette(palette), help: palette.localizedName) {
                        set(.palette(palette))
                    } fill: {
                        if let fill = palette.displayColor {
                            Circle().fill(Color(nsColor: fill))
                        } else {
                            NoColorMark()
                        }
                    }
                }

                Swatch(isSelected: isCustom, help: "Custom Color") {
                    if !isCustom { set(.custom(hue: seedHue, saturation: 0.6)) }
                } fill: {
                    Circle()
                        .fill(AngularGradient(colors: ColorPad.hues, center: .center))
                        .overlay {
                            if let custom = isCustom ? color.displayColor : nil {
                                Circle().fill(Color(nsColor: custom)).padding(3)
                            }
                        }
                }
            }

            if case .custom(let hue, let saturation) = color {
                ColorPad(hue: hue, saturation: saturation) { set(.custom(hue: $0, saturation: $1)) }
            }
        }
    }

    private var isCustom: Bool {
        if case .custom = color { return true }
        return false
    }

    /// The pad opens on the palette color's hue, so going custom starts from the current look.
    private var seedHue: Double {
        guard let current = color.displayColor?.usingColorSpace(.sRGB) else { return 0.6 }
        return Double(current.hueComponent)
    }
}

private struct Swatch<Fill: View>: View {
    let isSelected: Bool
    let help: String
    let action: () -> Void
    @ViewBuilder let fill: Fill

    var body: some View {
        Button(action: action) {
            fill
                .frame(width: 16, height: 16)
                .padding(3)
                .overlay(Circle().strokeBorder(Color.primary.opacity(isSelected ? 0.85 : 0), lineWidth: 1.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The None swatch: an empty ring, struck through.
private struct NoColorMark: View {
    var body: some View {
        Circle()
            .strokeBorder(Color.secondary.opacity(0.7), lineWidth: 1)
            .overlay(
                Capsule()
                    .fill(Color.secondary.opacity(0.9))
                    .frame(width: 1.5, height: 13)
                    .rotationEffect(.degrees(45)))
    }
}

/// Mixes a custom color: hue runs left to right, saturation fades out toward the bottom.
/// Dragging recolors the Workspace as it goes, as Arc's pad does.
private struct ColorPad: View {
    let hue: Double
    let saturation: Double
    let set: (Double, Double) -> Void

    /// Hue stops around the wheel, at the pad's brightness.
    static let hues = stride(from: 0.0, through: 1.0, by: 1.0 / 6).map { hue in
        Color(hue: hue, saturation: 1, brightness: WorkspaceColor.customBrightness)
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: Self.hues, startPoint: .leading, endPoint: .trailing)
                LinearGradient(
                    colors: [.white.opacity(0), .white],
                    startPoint: .top,
                    endPoint: .bottom)

                Circle()
                    .fill(Color(hue: hue, saturation: saturation, brightness: WorkspaceColor.customBrightness))
                    .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .frame(width: 14, height: 14)
                    .position(x: CGFloat(hue) * size.width, y: CGFloat(1 - saturation) * size.height)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                set(
                    Double(min(max(value.location.x / size.width, 0), 1)),
                    Double(min(max(1 - value.location.y / size.height, 0), 1)))
            })
        }
        .frame(height: 64)
        .accessibilityElement()
        .accessibilityLabel("Custom Color")
        .accessibilityValue("Hue \(Int(hue * 360)) degrees, saturation \(Int(saturation * 100)) percent")
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 1.0 / 36 : -1.0 / 36
            set((hue + step + 1).truncatingRemainder(dividingBy: 1), saturation)
        }
    }
}

// MARK: - Theme

/// The config's own colors first, then every theme, each with a chip of its colors.
/// Picking one, by click or by arrow key, themes the Workspace's Splits at once.
private struct ThemePicker: View {
    let theme: String?
    let set: (String?) -> Void

    @State private var query = ""
    @State private var names: [String] = []
    @FocusState private var searchFocused: Bool

    /// The Default row's tag. No theme file has an empty name.
    private static let configTag = ""

    private var matches: [String] {
        query.isEmpty ? names : names.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search Themes", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    // Return picks the best match.
                    .onSubmit { if let first = matches.first { set(first) } }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 7)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.06)))

            ScrollViewReader { proxy in
                List(selection: selection) {
                    if query.isEmpty {
                        ThemeRow(name: "Default", help: "The colors your config sets", preview: nil)
                            .tag(Self.configTag)
                            .id(Self.configTag)
                    }
                    ForEach(matches, id: \.self) { name in
                        ThemeRow(name: name, help: name, preview: ThemePreview.of(name))
                            .tag(name)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(height: 216)
                .onAppear {
                    names = Ghostty.Theme.names()
                    searchFocused = true
                    // A turn later, once the list has its rows.
                    DispatchQueue.main.async { proxy.scrollTo(theme ?? Self.configTag, anchor: .center) }
                }
            }
        }
    }

    /// The list's selection is the Workspace's theme, so moving it themes the Workspace.
    private var selection: Binding<String?> {
        Binding(
            get: { theme ?? Self.configTag },
            set: { picked in
                guard let picked else { return }
                set(picked == Self.configTag ? nil : picked)
            })
    }
}

private struct ThemeRow: View {
    let name: String
    let help: String
    /// Nil for the config's own colors, which have no file to read.
    let preview: ThemePreview?

    var body: some View {
        HStack(spacing: 8) {
            ThemeChip(preview: preview)
            Text(name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 1)
        .help(help)
    }
}

/// A theme's colors in miniature: its foreground on its background, then four of its
/// palette's colors.
private struct ThemeChip: View {
    let preview: ThemePreview?

    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(preview.map { Color(nsColor: $0.background) } ?? Color.primary.opacity(0.08))
            .overlay {
                if let preview {
                    HStack(spacing: 2) {
                        Text("Aa")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundColor(Color(nsColor: preview.foreground))
                            .padding(.trailing, 2)
                        ForEach(Array(preview.palette.enumerated()), id: \.offset) { _, color in
                            Circle().fill(Color(nsColor: color)).frame(width: 4, height: 4)
                        }
                    }
                } else {
                    Image(systemName: "gearshape")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
            .frame(width: 46, height: 20)
            .accessibilityHidden(true)
    }
}

/// The colors a theme's chip shows, read from its file on first use: background,
/// foreground, and palette entries 1, 2, 4, and 5 (red, green, blue, magenta).
private struct ThemePreview {
    let background: NSColor
    let foreground: NSColor
    let palette: [NSColor]

    @MainActor private static var cache: [String: ThemePreview] = [:]

    @MainActor static func of(_ name: String) -> ThemePreview? {
        if let cached = cache[name] { return cached }
        guard let url = Ghostty.Theme.url(named: name),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        let preview = ThemePreview(parsing: text)
        cache[name] = preview
        return preview
    }

    /// Reads `key = value` lines as Ghostty's config does, keeping the colors a chip needs.
    /// A color the theme leaves out takes Ghostty's default.
    init(parsing text: String) {
        var values: [String: String] = [:]
        var palette: [Int: NSColor] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            if parts[0] == "palette" {
                let entry = parts[1].split(separator: "=", maxSplits: 1)
                if entry.count == 2, let index = Int(entry[0].trimmingCharacters(in: .whitespaces)),
                   let color = NSColor(hex: String(entry[1])) {
                    palette[index] = color
                }
            } else {
                values[parts[0]] = parts[1]
            }
        }
        background = values["background"].flatMap(NSColor.init(hex:)) ?? NSColor(hex: "#282C34")!
        foreground = values["foreground"].flatMap(NSColor.init(hex:)) ?? NSColor(hex: "#FFFFFF")!
        self.palette = [1, 2, 4, 5].compactMap { palette[$0] }
    }
}
