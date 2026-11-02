import Foundation

/// Local storage records, separate from the generated network event contract.
/// Only these explicitly listed fields can reach disk; no audio or raw events.
public struct SavedCaption: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let text: String
    public let speakerID: String
    public var toneTag: String?
    public let tStart: Double
    public let tEnd: Double
    public var modelVersions: [String: String]

    public init(id: UUID = UUID(), text: String, speakerID: String,
                toneTag: String? = nil, tStart: Double, tEnd: Double,
                modelVersions: [String: String]) {
        self.id = id
        self.text = text
        self.speakerID = speakerID
        self.toneTag = toneTag
        self.tStart = tStart
        self.tEnd = tEnd
        self.modelVersions = modelVersions
    }
}

public struct SavedSession: Codable, Equatable, Identifiable, Sendable {
    public let storageVersion: Int
    public let id: UUID
    /// Wall date for display only; caption times and duration are monotonic offsets.
    public let startedAt: Date
    public var duration: Double
    public var captions: [SavedCaption]

    public init(id: UUID = UUID(), startedAt: Date = Date(), duration: Double,
                captions: [SavedCaption]) {
        storageVersion = 1
        self.id = id
        self.startedAt = startedAt
        self.duration = duration
        self.captions = captions
    }
}

public protocol SessionStore: Sendable {
    func save(_ session: SavedSession) async throws
    func loadSessions() async throws -> [SavedSession]
}

public enum SessionStorageError: Error {
    case unsupportedVersion(Int)
    case invalidTimings
}

/// One atomic JSON file per session in private Application Support, excluded from backup.
public actor FileSessionStore: SessionStore {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static func onDevice() throws -> FileSessionStore {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        return FileSessionStore(directory: support.appendingPathComponent("Sessions", isDirectory: true))
    }

    public func save(_ session: SavedSession) throws {
        try validate(session)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var directoryURL = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directoryURL.setResourceValues(values)
        let data = try JSONEncoder().encode(session)
        let url = directory.appendingPathComponent(session.id.uuidString).appendingPathExtension("json")
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }

    public func loadSessions() throws -> [SavedSession] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        return try urls.map { url in
            let session = try JSONDecoder().decode(SavedSession.self, from: Data(contentsOf: url))
            try validate(session)
            return session
        }.sorted { $0.startedAt > $1.startedAt }
    }

    private func validate(_ session: SavedSession) throws {
        guard session.storageVersion == 1 else {
            throw SessionStorageError.unsupportedVersion(session.storageVersion)
        }
        guard session.duration.isFinite, session.duration >= 0,
              Set(session.captions.map(\.id)).count == session.captions.count,
              session.captions.allSatisfy({
                  $0.tStart.isFinite && $0.tEnd.isFinite && $0.tStart >= 0
                      && $0.tEnd >= $0.tStart && $0.tEnd <= session.duration
              }) else { throw SessionStorageError.invalidTimings }
    }
}
