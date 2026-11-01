import Foundation

/// Import is a synchronous boundary on the main actor: flush a live reader first, replace
/// its persisted history, then rebuild its baseline before another page/clock callback runs.
@MainActor final class ReadingImportCoordinator {
    static let shared = ReadingImportCoordinator()
    private struct Observer {
        var root: URL
        var before: () -> Void
        var after: () -> Void
    }
    private var observers: [UUID: Observer] = [:]
    @discardableResult func register(root: URL, before: @escaping () -> Void, after: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = .init(root: root.standardizedFileURL, before: before, after: after)
        return id
    }
    func unregister(_ id: UUID) { observers.removeValue(forKey: id) }
    func apply<T>(root: URL, _ operation: () throws -> T) rethrows -> T {
        let matching = observers.values.filter { $0.root == root.standardizedFileURL }
        for observer in matching { observer.before() }
        defer { for observer in matching { observer.after() } }
        return try operation()
    }
}
