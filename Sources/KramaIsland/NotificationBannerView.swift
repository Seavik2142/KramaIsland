import AppKit
import SwiftUI

/// Flagship Dynamic Island notification banner:
/// - Subtle app-tinted obsidian glass wash
/// - Crisp 40×40 app icon with contextual badge (OTP / Meeting / Private)
/// - Live relative timestamp, optional multi-alert queue chip (`+N`), and hover quick actions
/// - One-click `Copy OTP` and `Join Meeting / Open Link` action pills
/// - Smooth bottom auto-dismiss hairline that pauses cleanly while hovering
struct NotificationBannerView: View {
    let note: NotchNotification
    let queueCount: Int
    let isHovered: Bool
    let duration: TimeInterval
    let onOpen: () -> Void
    let onDismiss: () -> Void
    let onOpenShade: () -> Void
    let onMuteApp: () -> Void
    let onCopyOTP: (String) -> Void
    let onOpenURL: (URL) -> Void

    @ObservedObject private var settings = AppSettings.shared
    @State private var copiedCode = false
    @State private var copiedText = false
    @State private var remainingFraction: CGFloat = 1.0

    private var hideBody: Bool { settings.privacyHideNotificationBody }
    private var showsSubtitle: Bool { !hideBody && !note.title.isEmpty && !note.subtitle.isEmpty && note.subtitle != note.sourceLabel }
    private var activeOTP: String? { (!hideBody && settings.notificationDetectOTP) ? note.otpCode : nil }
    private var activeURL: URL? { hideBody ? nil : note.actionURL }

    private var accentTint: Color {
        ArtworkPalette.color(for: note.icon) ?? note.category.tint
    }

    private var hasActions: Bool {
        activeOTP != nil || activeURL != nil || isHovered
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                appIconBadge

                VStack(alignment: .leading, spacing: 3) {
                    // Header eyebrow row: category dot, app/web source, time, queue pill, actions
                    HStack(spacing: 6) {
                        Circle()
                            .fill(note.category.tint)
                            .frame(width: 5.5, height: 5.5)
                        Text(note.sourceLabel.uppercased())
                            .font(UI.eyebrow)
                            .tracking(0.6)
                            .foregroundStyle(.white.opacity(0.68))
                            .lineLimit(1)

                        Spacer(minLength: 4)

                        if queueCount > 0 {
                            Button(action: onOpenShade) {
                                Text("+\(queueCount)")
                                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.92))
                                    .padding(.horizontal, 6)
                                    .frame(height: 18)
                                    .background(UI.info.opacity(0.28), in: Capsule())
                                    .overlay(Capsule().strokeBorder(UI.info.opacity(0.45), lineWidth: 0.5))
                            }
                            .buttonStyle(.plain)
                            .help("\(queueCount) more notification\(queueCount == 1 ? "" : "s") — click to open Shade")
                        }

                        Text(Self.relative(note.date))
                            .font(UI.caption())
                            .foregroundStyle(UI.secondaryText)

                        if isHovered {
                            IconButton(symbol: "bell.slash.fill", size: 20, help: "Mute \(note.appName) in KramaIsland", action: onMuteApp)
                                .transition(.opacity.combined(with: .scale(scale: 0.85)))
                        }
                        IconButton(symbol: "xmark", size: 20, help: "Dismiss", action: onDismiss)
                    }

                    // Primary headline
                    Text(note.headline)
                        .font(UI.title(13))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    // Optional secondary subtitle
                    if showsSubtitle {
                        Text(note.subtitle)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.84))
                            .lineLimit(1)
                    }

                    // Body text or privacy shield
                    if hideBody {
                        HStack(spacing: 5) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(UI.warning)
                            Text("Private notification preview hidden")
                                .font(UI.body(11))
                                .foregroundStyle(UI.secondaryText)
                        }
                        .padding(.top, 1)
                    } else if !note.body.isEmpty {
                        Text(note.body)
                            .font(UI.body(11.5))
                            .foregroundStyle(.white.opacity(0.70))
                            .lineLimit(showsSubtitle ? 2 : 3)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // Contextual smart action strip (OTP quick-copy, meeting join, hover open/copy)
                    if hasActions {
                        actionBar
                            .padding(.top, 5)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 11)
            .padding(.bottom, 12)

            // Ultra-thin countdown bar (pauses smoothly while hovered)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.white.opacity(0.06))
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [accentTint.opacity(0.75), accentTint],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * remainingFraction)
                }
            }
            .frame(height: 2)
            .padding(.horizontal, 18)
            .padding(.bottom, 6)
            .opacity(isHovered ? 0.35 : 0.85)
        }
        .background(
            LinearGradient(
                colors: [accentTint.opacity(0.16), Color.clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .allowsHitTesting(false)
        )
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .animation(Motion.quick, value: isHovered)
        .onAppear { startProgressBar() }
        .onChange(of: note.id) { _ in startProgressBar() }
        .onChange(of: isHovered) { hovering in
            if hovering {
                // Freeze bar at current visual height until mouse leaves
                withAnimation(.easeOut(duration: 0.12)) {
                    remainingFraction = max(remainingFraction, 0.25)
                }
            } else {
                withAnimation(.linear(duration: 1.5)) {
                    remainingFraction = 0
                }
            }
        }
    }

    private var appIconBadge: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(nsImage: note.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.35), radius: 6, y: 2)

            if let badge = cornerBadge {
                Image(systemName: badge.symbol)
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .background(badge.tint, in: Circle())
                    .overlay(Circle().strokeBorder(Color.black, lineWidth: 1.5))
                    .offset(x: 3, y: 3)
            }
        }
        .padding(.top, 1)
    }

    private var cornerBadge: (symbol: String, tint: Color)? {
        if hideBody { return ("lock.fill", UI.warning) }
        if activeOTP != nil { return ("key.fill", UI.info) }
        if activeURL != nil && note.isMeetingLink { return ("video.fill", UI.success) }
        return nil
    }

    private var actionBar: some View {
        HStack(spacing: 6) {
            if let code = activeOTP {
                Button {
                    copiedCode = true
                    onCopyOTP(code)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copiedCode ? "checkmark" : "key.fill")
                            .font(.system(size: 9.5, weight: .bold))
                        Text(copiedCode ? "Copied \(code)" : "Copy \(code)")
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }
                    .foregroundStyle(copiedCode ? Color.black : .white)
                    .padding(.horizontal, 9)
                    .frame(height: 23)
                    .background(copiedCode ? UI.success : UI.info.opacity(0.30), in: Capsule())
                    .overlay(Capsule().strokeBorder((copiedCode ? UI.success : UI.info).opacity(0.55), lineWidth: 0.75))
                }
                .buttonStyle(.plain)
            }

            if let url = activeURL {
                Button { onOpenURL(url) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: note.isMeetingLink ? "video.fill" : "arrow.up.right")
                            .font(.system(size: 9.5, weight: .bold))
                        Text(note.isMeetingLink ? "Join Meeting" : "Open Link")
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .frame(height: 23)
                    .background((note.isMeetingLink ? UI.success : UI.info).opacity(0.28), in: Capsule())
                    .overlay(Capsule().strokeBorder((note.isMeetingLink ? UI.success : UI.info).opacity(0.45), lineWidth: 0.75))
                }
                .buttonStyle(.plain)
            }

            if isHovered {
                PillButton(title: "Open", symbol: "arrow.up.forward.app.fill", small: true, action: onOpen)
                if !hideBody, !note.body.isEmpty || !note.title.isEmpty {
                    PillButton(title: copiedText ? "Copied" : "Copy", symbol: copiedText ? "checkmark" : "doc.on.doc", small: true) {
                        let text = [note.title, note.subtitle, note.body].filter { !$0.isEmpty }.joined(separator: "\n")
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(text, forType: .string)
                        Feedback.tap()
                        copiedText = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copiedText = false }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func startProgressBar() {
        copiedCode = false
        copiedText = false
        remainingFraction = 1.0
        guard !isHovered, duration > 0 else { return }
        DispatchQueue.main.async {
            withAnimation(.linear(duration: duration)) {
                remainingFraction = 0.0
            }
        }
    }

    static func relative(_ date: Date) -> String {
        let s = max(0, Int(Date().timeIntervalSince(date)))
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }
}
