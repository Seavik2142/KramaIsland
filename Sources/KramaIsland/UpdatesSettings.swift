import AppKit
import Combine
import SwiftUI

/// Settings ▸ Updates: this build, the latest release and its notes, Check Now / Update Now, and the
/// daily-check switches.
struct UpdatesSettingsView: View {
    @ObservedObject private var updater = Updater.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var now = Date()
    private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingSection("Installed Version") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center, spacing: 14) {
                        Image(nsImage: BrandIcon.image)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 52, height: 52)
                            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Text("KramaIsland \(Updater.currentVersion)")
                                    .font(.system(size: 14.5, weight: .bold))
                                statusPill
                            }
                            Text(statusLine)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let checked = updater.lastChecked {
                                Text("Last checked \(Self.relative(checked, now: now))")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer(minLength: 8)
                        actions.fixedSize()
                    }
                    progress
                    if case .failed(let message) = updater.phase {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                            Text(message)
                                .font(.system(size: 11))
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    if let release = updater.newer, !updater.canInstall {
                        Text(Permissions.isBundled
                             ? "This copy is signed ad hoc, so a download cannot be matched against it. Install \(release.version) from the release page."
                             : "Running from source: builds do not update in place. Install \(release.version) from the release page, or pull and build.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(14)
            }

            if let release = updater.newer {
                SettingSection("What's New in \(release.version)") {
                    notes(release)
                }
            } else if let release = updater.latest {
                SettingSection(Version.compare(release.version, Updater.currentVersion) == .orderedSame
                               ? "Release Notes" : "Latest Release: \(release.version)") {
                    notes(release)
                }
            }

            SettingSection("Automatic Updates") {
                SettingToggleRow(
                    symbol: "arrow.triangle.2.circlepath", tint: .blue,
                    title: "Check for updates daily",
                    subtitle: "Queries GitHub Releases once per day with zero telemetry",
                    isOn: $settings.updatesAutoCheck
                )
                SettingDivider()
                SettingToggleRow(
                    symbol: "bell.badge.fill", tint: .indigo,
                    title: "Announce in the island",
                    subtitle: "Show a brief HUD under the notch when a new release arrives",
                    isOn: $settings.updatesNotify
                )
                .disabled(!settings.updatesAutoCheck)
                .opacity(settings.updatesAutoCheck ? 1 : 0.55)
            }

            SettingSection("In-Place Verification") {
                SettingRow(
                    symbol: "checkmark.shield.fill", tint: .green,
                    title: "Signature-verified swap",
                    subtitle: "Downloads the release DMG, verifies it matches this copy's signing certificate so macOS permissions survive, swaps it in place, and relaunches."
                ) {
                    Button("GitHub Releases") { updater.openReleasePage() }
                        .controlSize(.small)
                }
            }
        }
        .onReceive(clock) { now = $0 }
    }

    // MARK: Pieces

    @ViewBuilder private var statusPill: some View {
        if updater.phase.isBusy {
            EmptyView()
        } else if updater.newer != nil {
            Text("Update Available")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.14), in: Capsule())
        } else if let latest = updater.latest,
                  Version.compare(latest.version, Updater.currentVersion) != .orderedDescending {
            Text("Up to Date")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.green)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.14), in: Capsule())
        }
    }

    @ViewBuilder private var actions: some View {
        switch updater.phase {
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        case .downloading, .installing, .relaunching:
            EmptyView()
        case .idle, .failed:
            if let release = updater.newer {
                HStack(spacing: 6) {
                    if updater.canInstall {
                        Button("Update Now") { updater.install() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .help("Download \(release.version) and install it in place")
                    } else {
                        Button("Download \(release.version)…") { updater.openReleasePage() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                    Button(updater.isSkipped ? "Show Again" : "Skip") { updater.skip(!updater.isSkipped) }
                        .controlSize(.small)
                }
            } else {
                Button("Check Now") { updater.check(manual: true) }
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder private var progress: some View {
        switch updater.phase {
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 5) {
                ProgressView(value: max(0, min(1, fraction)))
                Text("Downloading KramaIsland \(updater.newer?.version ?? "")… \(Self.bytes(fraction, of: updater.newer?.dmgSize ?? 0))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        case .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Verifying signature and installing…").font(.system(size: 11.5))
            }
        case .relaunching:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Installed. Relaunching…").font(.system(size: 11.5))
            }
        default:
            EmptyView()
        }
    }

    private func notes(_ release: AppRelease) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let date = release.publishedAt {
                Text("\(release.title) · \(date.formatted(date: .abbreviated, time: .omitted))")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
            if release.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("No notes for this release.").font(.system(size: 11.5)).foregroundStyle(.secondary)
            } else {
                ReleaseNotesView(markdown: release.notes)
            }
            Link("Open release page on GitHub ↗", destination: release.pageURL)
                .font(.system(size: 11.5, weight: .medium))
                .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusLine: String {
        switch updater.phase {
        case .checking: return "Checking GitHub for a newer version…"
        case .downloading, .installing, .relaunching: return "Updating…"
        case .idle, .failed: break
        }
        if let release = updater.newer {
            return "Version \(release.version) is available" + (updater.isSkipped ? " (skipped)" : "")
        }
        guard let latest = updater.latest else { return "Click Check Now to check GitHub Releases." }
        switch Version.compare(latest.version, Updater.currentVersion) {
        case .orderedSame: return "You're running the latest release."
        case .orderedAscending: return "This build is newer than the latest release (\(latest.version))."
        case .orderedDescending: return "Version \(latest.version) is available"
        }
    }

    static func relative(_ date: Date, now: Date) -> String {
        let s = Int(now.timeIntervalSince(date))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60) min ago" }
        if s < 86400 { return "\(s / 3600) h ago" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func bytes(_ fraction: Double, of total: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        guard total > 0 else { return String(format: "%.0f%%", fraction * 100) }
        return "\(f.string(fromByteCount: Int64(fraction * Double(total)))) of \(f.string(fromByteCount: total))"
    }
}

/// Enough Markdown for release notes: headings, bullets, numbered lists and paragraphs, with
/// inline bold / code / links. GitHub's notes are what the Changelog carries.
struct ReleaseNotesView: View {
    let markdown: String

    enum Block: Equatable {
        case heading(String)
        case bullet(String)
        case numbered(String, String)
        case paragraph(String)
    }

    var body: some View {
        let blocks = Self.parse(markdown)
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                switch block {
                case .heading(let text):
                    Text(text).font(.subheadline.weight(.semibold))
                        .padding(.top, index == 0 ? 0 : 6)
                case .bullet(let text):
                    HStack(alignment: .top, spacing: 6) {
                        Text("•").font(.system(size: 12)).foregroundStyle(.secondary)
                        inline(text)
                    }
                case .numbered(let n, let text):
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(n).").font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                        inline(text)
                    }
                case .paragraph(let text):
                    inline(text)
                }
            }
        }
        .textSelection(.enabled)
    }

    private func inline(_ text: String) -> some View {
        let rendered: Text
        if let a = try? AttributedString(markdown: text,
                                         options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            rendered = Text(a)
        } else {
            rendered = Text(text)
        }
        return rendered.font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
    }

    static func parse(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        for raw in markdown.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                let title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                if title.caseInsensitiveCompare("Install") == .orderedSame { break }
                blocks.append(.heading(title))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                blocks.append(.bullet(String(line.dropFirst(2))))
            } else if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
                      line[line.index(after: dot)...].hasPrefix(" ") {
                blocks.append(.numbered(String(line[..<dot]), line[line.index(after: dot)...].trimmingCharacters(in: .whitespaces)))
            } else {
                switch blocks.last {
                case .bullet(let t): blocks[blocks.count - 1] = .bullet(t + " " + line)
                case .numbered(let n, let t): blocks[blocks.count - 1] = .numbered(n, t + " " + line)
                case .paragraph(let t): blocks[blocks.count - 1] = .paragraph(t + " " + line)
                default: blocks.append(.paragraph(line))
                }
            }
        }
        return blocks
    }
}
