import SwiftUI

/// Dates as every device counts them: in the statistics time zone, never the device's own.
enum StatisticsFormat {
    private static var zone: TimeZone { StatisticsZone.calendar.timeZone }
    private static func style(_ base: Date.FormatStyle) -> Date.FormatStyle { var style = base; style.timeZone = zone; return style }
    /// "Nov 7"
    static func day(_ date: Date) -> String { date.formatted(style(.dateTime.month(.abbreviated).day())) }
    private static func thisYear(_ date: Date) -> Bool {
        StatisticsZone.calendar.component(.year, from: date) == StatisticsZone.calendar.component(.year, from: .now)
    }
    /// "Nov 7", with the year only when it is not this year.
    static func date(_ date: Date) -> String {
        thisYear(date) ? day(date) : date.formatted(style(.dateTime.month(.abbreviated).day().year()))
    }
    /// "Mon"
    static func weekday(_ date: Date) -> String { date.formatted(style(.dateTime.weekday(.abbreviated))) }
    /// "Nov"
    static func month(_ date: Date) -> String { date.formatted(style(.dateTime.month(.abbreviated))) }
    /// "Sat, Nov 7", with the year only when it is not this year.
    static func weekdayDay(_ date: Date) -> String {
        let base = Date.FormatStyle.dateTime.weekday(.abbreviated).month(.abbreviated).day()
        return date.formatted(style(thisYear(date) ? base : base.year()))
    }
    /// "Saturday, November 7"
    static func longDay(_ date: Date) -> String { date.formatted(style(.dateTime.weekday(.wide).month(.wide).day())) }
    static func time(_ date: Date) -> String { date.formatted(style(Date.FormatStyle(date: .omitted, time: .shortened))) }
    /// "3 AM"
    static func hour(_ date: Date) -> String { date.formatted(style(.dateTime.hour())) }
    /// A no-break space and a word joiner keep a range on one line rather than splitting it at the dash.
    static func timeRange(_ start: Date, _ end: Date) -> String { time(start) + "\u{00A0}–\u{2060}\u{00A0}" + time(end) }
    static func zoneName(_ zone: TimeZone) -> String {
        zone.localizedName(for: .generic, locale: .current) ?? zone.identifier.replacingOccurrences(of: "_", with: " ")
    }
    static func count(_ value: Int, _ singular: String, _ plural: String) -> String {
        "\(value.formatted()) \(value == 1 ? singular : plural)"
    }
}

/// Chips that wrap onto further lines instead of running off the screen.
struct StatisticsFlowLayout: Layout {
    var spacing: CGFloat = 8
    private func rows(_ width: CGFloat, _ subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        var frames: [CGRect] = [], x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: width.isFinite ? width : nil, height: nil))
            if x > 0, x + size.width > width { x = 0; y += line + spacing; line = 0 }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing; line = max(line, size.height); widest = max(widest, x - spacing)
        }
        return (CGSize(width: widest, height: y + line), frames)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        rows(proposal.width ?? .infinity, subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, rows(bounds.width, subviews).frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }
}

/// A title with a detail line and a value on the right; stacked at accessibility text sizes.
struct StatisticsSummaryRow: View {
    let title: String
    var subtitle: String?
    let value: String
    var titleLines = 2
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        layout {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(typeSize.isAccessibilitySize ? nil : titleLines)
                if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
            }
            if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
            Text(value).fontWeight(.semibold).monospacedDigit()
        }
    }
}

/// Keeps a list to a readable column on wide iPad windows instead of stretching every card.
struct StatisticsReadableWidth: ViewModifier {
    @State private var width: CGFloat = 0
    func body(content: Content) -> some View {
        content
            .contentMargins(.horizontal, width > 760 ? (width - 680) / 2 : nil, for: .scrollContent)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

/// One colour per book, the most-read first; past the palette the rest share grey.
struct StatisticsBookColors {
    static let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal]
    static let other = "Other books"
    let names: [String]
    init(spans: [UsageSpan]) {
        let totals = spans.reduce(into: [String: Double]()) { $0[$1.title, default: 0] += $1.seconds }
        let ordered = totals.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
        names = ordered.count > Self.palette.count ? Array(ordered.prefix(Self.palette.count - 1)) + [Self.other] : ordered
    }
    func name(_ title: String) -> String { names.contains(title) ? title : Self.other }
    func color(_ title: String) -> Color {
        names.firstIndex(of: name(title)).map { name(title) == Self.other ? Color.gray : Self.palette[$0] } ?? .gray
    }
}
