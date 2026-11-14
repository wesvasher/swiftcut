import Foundation

/// A folder in the sidebar's Source Videos, made when a folder is dropped on the window. It holds
/// the clips made from what was in it, and folders for its subfolders. Only the project's own
/// list: the files on disk aren't moved.
nonisolated struct MediaFolder: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    /// The folder it's inside, or `nil` at the top.
    var parentID: UUID?
    /// Where it came from on disk, for Show in Finder and keeping it in sync.
    var path: String?
    /// Permission to read the folder after relaunching (the app is sandboxed), so it can be
    /// watched and synced. Saved for top-level folders; folders inside are reached through them.
    var bookmark: Data?

    init(id: UUID = UUID(), name: String, parentID: UUID? = nil, path: String? = nil, bookmark: Data? = nil) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.path = path
        self.bookmark = bookmark
    }

    var url: URL? { path.map { URL(filePath: $0, directoryHint: .isDirectory) } }
}

/// Where a watched folder stands, for the sidebar's status icon. Not saved.
enum FolderSyncState: Equatable {
    /// Matches the folder on disk, as of `at`.
    case upToDate(at: Date)
    case syncing
    /// Matches as far as it can, but something needs a look (`message` says what).
    case attention(String)
    /// The folder can't be read: moved, deleted, on a drive that isn't connected, or no permission.
    case unavailable(String)
}
