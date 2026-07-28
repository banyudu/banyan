/// Persistence operations required by a frontend-independent session store.
///
/// The current macOS implementation also persists workspace and Linear cache
/// state. Those concerns remain in the macOS target until their own portable
/// representations are extracted.
public protocol SessionPersistenceBackend: Sendable {
    func load() -> [SessionSnapshot]
    func save(_ snapshots: [SessionSnapshot])
}
