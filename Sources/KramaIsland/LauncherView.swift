import SwiftUI

/// Spotlight / Raycast-style command launcher drawn on the island's black surface: apps (fuzzy,
/// recent/frequent first), calculator, unit conversion, quick actions, and file search.
struct LauncherView: View {
    @ObservedObject var state: IslandState
    @ObservedObject var engine: LauncherEngine
    @FocusState private var focused: Bool
    @State private var selection = 0

    private var results: [LauncherItem] { state.results }
    private var selectedItem: LauncherItem? {
        guard !results.isEmpty else { return nil }
        return results[min(selection, results.count - 1)]
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            HairlineDivider()
            resultsArea
            HairlineDivider()
            footerBar
        }
        .frame(maxWidth: .infinity)
        .foregroundStyle(.white)
        .onAppear { focused = true; selection = 0 }
        .onMoveCommand { direction in
            let count = results.count
            guard count > 0 else { return }
            switch direction {
            case .down: selection = (selection + 1) % count
            case .up: selection = (selection - 1 + count) % count
            default: break
            }
        }
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 11) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15.5, weight: .semibold))
                .foregroundStyle(state.query.isEmpty ? UI.secondaryText : .white.opacity(0.9))
            ZStack(alignment: .leading) {
                if state.query.isEmpty {
                    Text("Search apps, files, or commands…")
                        .font(.system(size: 17.5, weight: .regular))
                        .foregroundStyle(UI.tertiaryText)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                }
                TextField("", text: $state.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17.5, weight: .regular))
                    .foregroundStyle(.white)
                    .focused($focused)
                    .onSubmit { performSelected() }
                    .onExitCommand { state.closeLauncher() }
                    .onChange(of: state.query) { _ in selection = 0 }
            }
            if !state.query.isEmpty {
                Button {
                    state.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(UI.tertiaryText)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            } else {
                KeyCap(text: formattedHotkey)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 13)
    }

    private var formattedHotkey: String {
        AppSettings.shared.hotkeyDescription.replacingOccurrences(of: "Space", with: " Space")
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsArea: some View {
        if results.isEmpty {
            VStack(spacing: 8) {
                IconBadge(symbol: "magnifyingglass", tint: UI.secondaryText, size: 38)
                Text("No matching results")
                    .font(UI.title(13))
                Text("Try an app name, math like 12*3, 5 km to mi, or timer 25")
                    .font(UI.body(11))
                    .foregroundStyle(UI.secondaryText)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.query.trimmingCharacters(in: .whitespaces).isEmpty ? "SUGGESTIONS" : "RESULTS")
                        .font(UI.eyebrow)
                        .tracking(0.8)
                        .foregroundStyle(UI.tertiaryText)
                        .padding(.horizontal, 12)
                        .padding(.top, 4)
                        .padding(.bottom, 4)

                    ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                        let isSelected = index == selection
                        Group {
                            if Self.isFeatured(item) {
                                featuredRow(item, selected: isSelected)
                            } else {
                                standardRow(item, selected: isSelected)
                            }
                        }
                        .onTapGesture { state.perform(item) }
                        .onHover { if $0 { selection = index } }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .frame(maxHeight: state.layout.launcherListHeight(state.geometry))
            .scrollIndicators(.never)
        }
    }

    /// Featured split card for calculator & unit conversion results.
    private func featuredRow(_ item: LauncherItem, selected: Bool) -> some View {
        let isCalc: Bool = { if case .calc = item.kind { return true }; return false }()
        let tint = isCalc ? UI.info : UI.focus
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

        return HStack(spacing: 12) {
            IconBadge(symbol: item.symbol ?? "equal", tint: tint, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.subtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(UI.secondaryText)
                    .lineLimit(1)
                Text(isCalc ? "Calculator" : "Unit Conversion")
                    .font(UI.caption(10))
                    .foregroundStyle(UI.tertiaryText)
            }
            Spacer(minLength: 8)
            Text(item.title)
                .font(UI.numeral(22))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
            if selected {
                KeyCap(text: "↩")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(selected ? tint.opacity(0.18) : tint.opacity(0.10), in: shape)
        .overlay(shape.strokeBorder(selected ? tint.opacity(0.40) : tint.opacity(0.20), lineWidth: 1))
        .contentShape(shape)
        .padding(.bottom, 4)
    }

    /// Crisp single-line row for apps, commands, and files.
    private func standardRow(_ item: LauncherItem, selected: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

        return HStack(spacing: 11) {
            if let image = item.image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 24, height: 24)
            } else {
                IconBadge(symbol: item.symbol ?? "bolt.fill", tint: Self.actionTint(for: item), size: 24)
            }

            Text(item.title)
                .font(.system(size: 13.5, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? .white : .white.opacity(0.90))
                .lineLimit(1)

            if case .file = item.kind {
                Text(item.subtitle)
                    .font(UI.body(11))
                    .foregroundStyle(UI.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            if selected {
                HStack(spacing: 6) {
                    Text(Self.actionVerb(for: item))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(UI.secondaryText)
                    KeyCap(text: "↩")
                }
            } else if case .file = item.kind {
                Text("File")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(UI.tertiaryText)
            } else {
                Text(item.subtitle)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(UI.tertiaryText)
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 36)
        .background(selected ? Color.white.opacity(0.11) : Color.clear, in: shape)
        .overlay(shape.strokeBorder(selected ? UI.cardEdge : LinearGradient(colors: [.clear], startPoint: .top, endPoint: .bottom), lineWidth: 0.75))
        .contentShape(shape)
    }

    // MARK: - Footer bar

    private var footerBar: some View {
        HStack(spacing: 12) {
            if state.query.trimmingCharacters(in: .whitespaces).isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(UI.tertiaryText)
                    Text("12*3  ·  5 km to mi  ·  timer 25  ·  clip")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(UI.tertiaryText)
                }
            } else {
                Text("\(results.count) \(results.count == 1 ? "result" : "results")")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(UI.tertiaryText)
            }
            Spacer()
            HStack(spacing: 10) {
                footerHint(keys: "↑↓", label: "Navigate")
                if let item = selectedItem {
                    footerHint(keys: "↩", label: Self.actionVerb(for: item))
                }
                footerHint(keys: "Esc", label: "Close")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 34)
        .background(Color.white.opacity(0.025))
    }

    private func footerHint(keys: String, label: String) -> some View {
        HStack(spacing: 4) {
            Text(keys)
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .foregroundStyle(UI.secondaryText)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(UI.controlFill, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(UI.tertiaryText)
        }
    }

    // MARK: - Helpers

    private static func isFeatured(_ item: LauncherItem) -> Bool {
        switch item.kind {
        case .calc, .convert: return true
        default: return false
        }
    }

    private static func actionVerb(for item: LauncherItem) -> String {
        switch item.kind {
        case .app, .file: return "Open"
        case .calc, .convert, .clipboard: return "Copy"
        case .action: return "Run"
        }
    }

    private static func actionTint(for item: LauncherItem) -> Color {
        guard case .action(let action) = item.kind else { return UI.info }
        if action.id.hasPrefix("timer") || action.id == "pomodoro" { return UI.timer }
        if action.id.hasPrefix("window.") || action.id.hasPrefix("tile.") { return UI.info }
        switch action.id {
        case "dark": return Color(red: 0.44, green: 0.54, blue: 1.00)
        case "awake": return UI.mic
        case "wifi": return UI.info
        case "mirror": return UI.camera
        case "quiet", "quiet.hour": return Color(red: 0.96, green: 0.44, blue: 0.50)
        case "lock", "sleep": return UI.focus
        case "trash": return UI.danger
        default: return UI.secondaryText
        }
    }

    private func performSelected() {
        let items = results
        guard !items.isEmpty else { return }
        state.perform(items[min(selection, items.count - 1)])
    }
}
