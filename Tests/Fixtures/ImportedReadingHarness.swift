import Foundation

nonisolated struct ReadingDevice { let id: String; let name: String }
nonisolated enum ReadingDay {
    static func sumHours(_ groups: [[String: Double]]) -> [String: Double] {
        groups.reduce(into: [:]) { result, group in
            for (key, value) in group { result[key, default: 0] += value }
        }
    }
}
@main struct ImportedReadingHarness {
    static func main() throws {
        func row(_ device: String?, _ seconds: Double, _ count: Int) -> Statistics {
            var value = Statistics.empty(title: "Fixture", day: "2026-10-31")
            value.deviceId = device; value.readingTime = seconds; value.charactersRead = count; value.lastStatisticModified = 100
            return value
        }
        let external = row(nil, 100, 1000)
        let phone = ImportedReadingTotals.applying([external], to: [row("phone", 20, 200)], replace: false)
        let tablet = ImportedReadingTotals.applying([external], to: [row("tablet", 30, 300)], replace: false)
        let merged = Statistics.merged(phone + tablet)
        precondition(Statistics.total(merged).readingTime == 100 && Statistics.total(merged).charactersRead == 1000)
        precondition(merged == Statistics.merged(tablet + phone))
        precondition(ImportedReadingTotals.applying([external], to: merged, replace: false) == merged)
        let newReading = row("third", 5, 50)
        let cleared = ImportedReadingTotals.applying([], to: merged + [newReading], replace: true)
        precondition(Statistics.total(Statistics.merged(merged + cleared)).readingTime == 55)
        precondition(Statistics.total(Statistics.merged(cleared + merged)).charactersRead == 550)
        let encoded = try JSONEncoder().encode(merged)
        let decoded = try JSONDecoder().decode([Statistics].self, from: encoded)
        precondition(decoded == merged)
        var rich = phone.first { $0.deviceId == Statistics.ttuDeviceId }!
        var plain = rich
        rich.importedBaseline!.readingTimeByHour = ["2026-10-31T10:00": 100]
        rich.importedBaseline!.timeZone = "Asia/Tokyo"
        rich.importedBaseline!.includedDevices["phone"]!.readingTimeByHour = ["2026-10-31T10:00": 20]
        rich.importedBaseline!.includedDevices["phone"]!.timeZone = "Asia/Tokyo"
        plain.importedBaseline!.readingTimeByHour = rich.importedBaseline!.readingTimeByHour
        plain.importedBaseline!.timeZone = "Asia/Tokyo"
        let richerFirst = Statistics.merged([rich, plain]), richerLast = Statistics.merged([plain, rich])
        precondition(richerFirst == richerLast)
        precondition(richerFirst.first!.readingTimeByHour["2026-10-31T10:00"] == 80)
        var corrupt = row("malformed", 1, 1)
        corrupt.lastStatisticModified = Int.max
        let malformed = try JSONEncoder().encode(corrupt)
        do { _ = try JSONDecoder().decode(Statistics.self, from: malformed); preconditionFailure("Accepted invalid clock") }
        catch { }
        print("TTU imports: duplicate devices, checkpoint convergence, repeat import, replacement tombstones and wire round-trip passed")
    }
}
