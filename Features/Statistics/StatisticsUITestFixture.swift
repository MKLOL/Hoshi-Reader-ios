#if DEBUG
import SwiftUI

/// Synthetic data for native statistics UI checks; enabled only by the test runner.
struct StatisticsUITestFixture: View {
    @State private var ready = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            if ready { StatisticsOverviewView() }
            else if let error { Text(error) }
            else { ProgressView("Preparing statistics") }
        }
        .task {
            guard !ready else { return }
            do {
                let now = Date(), calendar = StatisticsZone.calendar
                let day = ReadingDay.key(now, calendar: calendar)
                let root = try StatisticsHistory.historyRoot("ui-history", title: "Retained reading history", type: .epub)
                var row = Statistics.empty(title: "Retained reading history", day: day, device: ReadingDevice(id: "android-ui", name: "Android tablet"))
                row.readingTime = 900; row.charactersRead = 1500; row.lastStatisticModified = Int(now.timeIntervalSince1970 * 1000)
                row.timeZone = calendar.timeZone.identifier
                row.readingTimeByHour = [day + String(format: "T%02d:00", calendar.component(.hour, from: now)): 900]
                try ReadingStatisticsStore.save([row], root: root, scheduleSync: false)
                var data = Data()
                for (index, type) in [UsageEventType.lookup, .lookup, .revealed, .translated].enumerated() {
                    let event = UsageEvent(at: Int64(now.timeIntervalSince1970 * 1000) + Int64(index), utcOffset: "-04:00", type: type, session: "ui-session", bookTitle: "Retained reading history", contentType: "manga", term: type == .lookup ? "猫" : nil, source: "page", outcome: "found")
                    data.append(try JSONEncoder().encode(event)); data.append(10)
                }
                try await UsageLog.shared.store(days: [day: data], device: "android-ui", mergeOwn: false)
                ready = true
            } catch { self.error = error.localizedDescription }
        }
    }
}
#endif
