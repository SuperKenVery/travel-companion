import Foundation

actor ValidationEventStore {
    private let fileURL: URL
    private var events: [ReplicatedTextEvent]

    init(fileManager: FileManager = .default, directory customDirectory: URL? = nil) {
        let directory = customDirectory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appending(path: "Validation", directoryHint: .isDirectory)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appending(path: "events.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([ReplicatedTextEvent].self, from: data) {
            events = decoded
        } else {
            events = []
        }
    }

    func append(_ event: ReplicatedTextEvent) -> Bool {
        guard !events.contains(where: { $0.id == event.id }) else { return false }
        events.append(event)
        events.sort { ($0.sequence, $0.senderID.uuidString) < ($1.sequence, $1.senderID.uuidString) }
        persist()
        return true
    }

    func events(after cursor: UInt64) -> [ReplicatedTextEvent] {
        return events.filter { $0.sequence > cursor }
    }

    func latestCursor() -> UInt64 {
        return events.map(\.sequence).max() ?? 0
    }

    func allEvents() -> [ReplicatedTextEvent] {
        events
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(events) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
