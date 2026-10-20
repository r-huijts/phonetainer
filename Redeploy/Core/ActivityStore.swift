import Foundation
import Observation

struct ActivityEntry: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    let stackId: Int
    let stackName: String
    let date: Date
    let succeeded: Bool
    let message: String
    let duration: TimeInterval
}

/// Local history of redeploys, newest first, persisted as JSON in Application Support.
@Observable @MainActor
final class ActivityStore {
    static let limit = 50

    private(set) var entries: [ActivityEntry] = []
    @ObservationIgnored private let fileURL: URL?

    nonisolated static var defaultFileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("activity.json")
    }

    /// Pass nil to keep the history in memory only.
    init(fileURL: URL? = ActivityStore.defaultFileURL) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL) {
            entries = (try? Self.decoder.decode([ActivityEntry].self, from: data)) ?? []
        }
    }

    func record(_ entry: ActivityEntry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.limit {
            entries.removeLast(entries.count - Self.limit)
        }
        persist()
    }

    func clear() {
        entries = []
        persist()
    }

    private func persist() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encoder.encode(entries).write(to: fileURL, options: [.atomic])
        } catch {
            // History is a convenience; losing it is not worth interrupting the user.
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
