import EventKit
import SwiftUI

/// Next calendar event (within 24 h) and its meeting link, via EventKit.
final class CalendarModule: ObservableObject {
    struct NextEvent: Equatable {
        let title: String
        let start: Date
        let end: Date
        let location: String?
        let joinURL: URL?
        let color: Color

        var isNow: Bool { start <= Date() && end > Date() }
        var relative: String {
            let now = Date()
            if isNow { return "Now · ends \(Self.clock(end))" }
            let minutes = Int(start.timeIntervalSince(now) / 60)
            if minutes < 1 { return "Starting now" }
            if minutes < 60 { return "in \(minutes) min · \(Self.clock(start))" }
            if minutes < 24 * 60 { return "\(Self.clock(start))" + (Calendar.current.isDateInToday(start) ? "" : " tomorrow") }
            return Self.clock(start)
        }
        private static let clockFormatter: DateFormatter = {
            let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none
            return f
        }()
        static func clock(_ d: Date) -> String { clockFormatter.string(from: d) }
        static func == (a: NextEvent, b: NextEvent) -> Bool {
            a.title == b.title && a.start == b.start && a.end == b.end && a.joinURL == b.joinURL
        }
    }

    @Published private(set) var next: NextEvent?
    @Published private(set) var status = EKEventStore.authorizationStatus(for: .event)

    private let store = EKEventStore()
    private var timer: Timer?
    private var observer: Any?
    private var resetObserver: Any?

    init() {
        // After `tccutil reset` the status goes back to "not determined" and the shade shows Allow again.
        resetObserver = NotificationCenter.default.addObserver(forName: .notchPermissionsReset, object: nil, queue: .main) { [weak self] _ in
            self?.status = EKEventStore.authorizationStatus(for: .event)
        }
    }

    var isAuthorized: Bool {
        if #available(macOS 14, *) { return status == .fullAccess }
        return status == .authorized
    }
    var canAsk: Bool { status == .notDetermined }

    func start() {
        status = EKEventStore.authorizationStatus(for: .event)
        guard isAuthorized else { return }
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    func requestAccess() {
        let finish: (Bool) -> Void = { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                self.status = EKEventStore.authorizationStatus(for: .event)
                if granted { self.start() }
            }
        }
        if #available(macOS 14, *) {
            store.requestFullAccessToEvents { granted, _ in finish(granted) }
        } else {
            store.requestAccess(to: .event) { granted, _ in finish(granted) }
        }
    }

    /// Demo mode: show a sample event without touching EventKit.
    func seed(_ event: NextEvent) {
        stop()
        next = event
    }

    func refresh() {
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-15 * 60),
                                                 end: now.addingTimeInterval(24 * 3600), calendars: nil)
        let events = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }
        guard let e = events.first else {
            if next != nil { next = nil }
            return
        }
        let join = Self.joinLink(in: [e.url?.absoluteString, e.location, e.notes])
        let color = e.calendar.cgColor.map { Color(cgColor: $0) } ?? Theme.accent
        let candidate = NextEvent(title: e.title ?? "Event", start: e.startDate, end: e.endDate,
                                  location: e.location, joinURL: join, color: color)
        if candidate != next { next = candidate }
    }

    private static let linkPattern = try! NSRegularExpression(
        pattern: #"https?://[^\s<>"')\]]+"#, options: [])
    private static let meetingHosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com",
                                       "webex.com", "whereby.com", "gotomeeting.com", "facetime.apple.com",
                                       "around.co", "meet.jit.si", "slack.com/huddle"]

    static func joinLink(in texts: [String?]) -> URL? {
        for text in texts.compactMap({ $0 }) {
            let ns = text as NSString
            for m in linkPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let s = ns.substring(with: m.range)
                if meetingHosts.contains(where: { s.contains($0) }), let url = URL(string: s) { return url }
            }
        }
        return nil
    }
}

/// Compact macOS Calendar-style date icon: colored month strip over the day numeral.
struct CalendarDateBadge: View {
    let date: Date
    let tint: Color
    var size: CGFloat = 38

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM"; return f
    }()

    private var month: String { Self.monthFormatter.string(from: date).uppercased() }
    private var day: String {
        String(Calendar.current.component(.day, from: date))
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        VStack(spacing: 0) {
            Text(month)
                .font(.system(size: 7.5, weight: .bold))
                .tracking(0.3)
                .foregroundStyle(Theme.on(tint))
                .frame(maxWidth: .infinity)
                .frame(height: size * 0.34)
                .background(tint)
            Text(day)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white.opacity(0.09))
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 0.75))
    }
}

/// Row for the shade / hover island.
struct CalendarRow: View {
    @ObservedObject var calendar: CalendarModule

    var body: some View {
        if let e = calendar.next {
            HStack(spacing: 12) {
                CalendarDateBadge(date: e.start, tint: e.color, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(e.title).font(UI.title(13)).lineLimit(1)
                    HStack(spacing: 5) {
                        if e.isNow {
                            Circle().fill(UI.success).frame(width: 6, height: 6)
                        }
                        Text(e.relative)
                            .font(UI.body(11))
                            .foregroundStyle(e.isNow ? UI.success : UI.secondaryText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                if let url = e.joinURL {
                    PillButton(title: "Join", symbol: "video.fill", prominent: true, help: url.host ?? "Join") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            .foregroundStyle(.white)
            .islandCard(padding: 12)
        } else if calendar.canAsk {
            HStack(spacing: 12) {
                IconBadge(symbol: "calendar.badge.plus", tint: UI.info, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Next event").font(UI.title())
                    Text("See what's coming up and join calls from here")
                        .font(UI.body(10.5)).foregroundStyle(UI.secondaryText).lineLimit(1)
                }
                Spacer(minLength: 6)
                PillButton(title: "Allow", help: "Allow calendar access") { calendar.requestAccess() }
            }
            .foregroundStyle(.white)
            .islandCard(padding: 12)
        }
    }
}
