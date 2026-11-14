import Foundation

/// A folder in the sidebar's Source Videos, made when a folder is dropped on the window. It holds
/// the clips made from what was in it, and folders for its subfolders. Only the project's own
/// list: the files on disk aren't moved.
nonisolated struct MediaFolder: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    /// The folder it's inside, or `nil` at the top.
    var parentID: UUID?
    /// Where it came from on disk, for Show in Finder.
    var path: String?

    init(id: UUID = UUID(), name: String, parentID: UUID? = nil, path: String? = nil) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.path = path
    }
}
