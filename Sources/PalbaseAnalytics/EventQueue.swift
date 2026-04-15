import Foundation

/// Local event queue with NDJSON persistence. Events survive app termination;
/// hydration happens on first `load()` call.
///
/// Persistence format: one JSON event per line at
/// `<Application Support>/Palbase/analytics-queue/queue.ndjson`.
///
/// The queue is FIFO — on overflow, the oldest events are dropped to preserve
/// freshness. Each `append` triggers an asynchronous write; `drain` removes the
/// supplied prefix and rewrites the file.
package actor EventQueue {
    private var events: [QueuedEvent] = []
    private let maxSize: Int
    private let fileURL: URL?
    private var hydrated: Bool = false

    /// Production init — uses the default application support directory.
    package init(maxSize: Int = AnalyticsLimits.maxQueueSize) {
        self.maxSize = maxSize
        if let dir = Self.defaultDirectory() {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("queue.ndjson")
        } else {
            self.fileURL = nil
        }
    }

    /// Designated init for tests / custom persistence. Pass `nil` for an
    /// in-memory queue.
    package init(maxSize: Int = AnalyticsLimits.maxQueueSize, directory: URL?) {
        self.maxSize = maxSize
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.fileURL = directory.appendingPathComponent("queue.ndjson")
        } else {
            self.fileURL = nil
        }
    }

    /// Test-only: construct an in-memory queue without disk persistence.
    package static func inMemory(maxSize: Int = AnalyticsLimits.maxQueueSize) -> EventQueue {
        EventQueue(maxSize: maxSize, directory: nil)
    }

    /// Hydrate from disk if not done already. Safe to call repeatedly.
    package func load() {
        guard !hydrated else { return }
        hydrated = true
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else { return }
        let decoder = JSONDecoder.palbaseDefault
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8) else { continue }
            if let ev = try? decoder.decode(QueuedEvent.self, from: lineData) {
                events.append(ev)
            }
        }
        if events.count > maxSize {
            events.removeFirst(events.count - maxSize)
            persist()
        }
    }

    /// Append a new event. Drops the oldest when over capacity.
    package func append(_ event: QueuedEvent) {
        if !hydrated { load() }
        events.append(event)
        if events.count > maxSize {
            events.removeFirst(events.count - maxSize)
        }
        persist()
    }

    /// Snapshot of up to `batchSize` oldest events, capped by serialized byte budget.
    package func drain(batchSize: Int, maxBytes: Int) -> [QueuedEvent] {
        if !hydrated { load() }
        guard !events.isEmpty else { return [] }
        let encoder = JSONEncoder.palbaseDefault
        var taken: [QueuedEvent] = []
        var runningBytes = 0
        for ev in events.prefix(batchSize) {
            guard let data = try? encoder.encode(ev) else { continue }
            if runningBytes + data.count > maxBytes {
                if taken.isEmpty {
                    // Single event already exceeds limit — take it so caller
                    // can reject it via size validation.
                    taken.append(ev)
                }
                break
            }
            taken.append(ev)
            runningBytes += data.count
        }
        return taken
    }

    /// Remove events whose `eventId` is in `ids`.
    package func remove(ids: Set<String>) {
        events.removeAll { ids.contains($0.eventId) }
        persist()
    }

    /// Count (after hydration).
    package func count() -> Int {
        if !hydrated { load() }
        return events.count
    }

    /// Wipe everything.
    package func clear() {
        events.removeAll()
        persist()
    }

    /// Test inspection.
    package func snapshot() -> [QueuedEvent] {
        if !hydrated { load() }
        return events
    }

    private func persist() {
        guard let fileURL else { return }
        let encoder = JSONEncoder.palbaseDefault
        var buffer = Data()
        for ev in events {
            guard let data = try? encoder.encode(ev) else { continue }
            buffer.append(data)
            buffer.append(0x0A)  // newline
        }
        try? buffer.write(to: fileURL, options: .atomic)
    }

    private static func defaultDirectory() -> URL? {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        return base.appendingPathComponent("Palbase/analytics-queue", isDirectory: true)
    }
}
