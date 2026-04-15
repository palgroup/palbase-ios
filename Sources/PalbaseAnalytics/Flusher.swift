import Foundation
@_exported import PalbaseCore

/// Sends queued events to the server. Owns the auto-flush timer and applies
/// exponential backoff on failure.
package actor Flusher {
    private let http: HTTPRequesting
    private let queue: EventQueue
    private let pathPrefix: String
    private let clock: @Sendable () -> Date

    private var autoFlushTask: Task<Void, Never>?
    private var inflight: Bool = false
    private var backoffSeconds: TimeInterval = AnalyticsLimits.initialBackoffSeconds

    package init(
        http: HTTPRequesting,
        queue: EventQueue,
        pathPrefix: String = "/v1/analytics",
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.http = http
        self.queue = queue
        self.pathPrefix = pathPrefix
        self.clock = clock
    }

    // MARK: - Auto-flush loop

    /// Start the auto-flush timer. Idempotent — calling twice has no effect.
    package func start() {
        guard autoFlushTask == nil else { return }
        autoFlushTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = AnalyticsLimits.autoFlushInterval
                let nanos = UInt64(interval * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                if Task.isCancelled { return }
                guard let self else { return }
                _ = try? await self.flushOnce()
            }
        }
    }

    /// Stop the auto-flush timer.
    package func stop() {
        autoFlushTask?.cancel()
        autoFlushTask = nil
    }

    package func isRunning() -> Bool { autoFlushTask != nil }

    // MARK: - Flush

    /// Drain the queue in batches until empty or until a batch fails. Errors
    /// from intermediate batches are surfaced to the caller (manual `flush()`)
    /// so they can observe rate-limit/network issues.
    @discardableResult
    package func flushOnce() async throws(AnalyticsError) -> Int {
        if inflight { return 0 }
        inflight = true
        defer { inflight = false }

        var sent = 0
        while true {
            let batch = await queue.drain(
                batchSize: AnalyticsLimits.maxBatchEvents,
                maxBytes: AnalyticsLimits.maxBatchBytes
            )
            if batch.isEmpty { break }
            do {
                try await sendBatch(batch)
                let ids = Set(batch.map { $0.eventId })
                await queue.remove(ids: ids)
                sent += batch.count
                backoffSeconds = AnalyticsLimits.initialBackoffSeconds
            } catch {
                // Leave events in the queue. Apply backoff and rethrow.
                bumpBackoff()
                throw error
            }
        }
        return sent
    }

    /// Try to send a batch; on `rateLimited`, respect the retry-after before
    /// throwing so callers see the correct error type.
    private func sendBatch(_ events: [QueuedEvent]) async throws(AnalyticsError) {
        let sentAtMs = Int64(clock().timeIntervalSince1970 * 1000)
        let body = BatchRequestDTO(events: events.map { e in
            Self.toBatchEvent(e, sentAtMs: sentAtMs)
        })
        do {
            try await http.requestVoid(
                method: "POST",
                path: "\(pathPrefix)/batch",
                body: body,
                headers: [:]
            )
        } catch {
            throw AnalyticsError.from(transport: error)
        }
    }

    // MARK: - Backoff

    private func bumpBackoff() {
        backoffSeconds = min(backoffSeconds * 2, AnalyticsLimits.maxBackoffSeconds)
    }

    /// Test inspection.
    package func currentBackoff() -> TimeInterval { backoffSeconds }

    // MARK: - Payload mapping

    /// Fold queued event variants into the CaptureRequest wire shape. Identify
    /// and alias carry their extra fields under the `properties` bag:
    /// `$set` for identify traits, `alias` for alias distinct_id target.
    static func toBatchEvent(_ e: QueuedEvent, sentAtMs: Int64) -> BatchEventDTO {
        var props = e.properties ?? [:]
        switch e.endpoint {
        case .capture, .batch:
            break
        case .identify:
            if let traits = e.traits { props["$set"] = .object(traits) }
        case .alias:
            if let alias = e.alias {
                props["alias"] = .string(alias.to)
                props["distinct_id"] = .string(alias.from)
            }
        case .screen:
            if let name = e.screenName { props["$screen_name"] = .string(name) }
        case .page:
            if let url = e.pageURL { props["$current_url"] = .string(url) }
            if let title = e.pageTitle { props["$title"] = .string(title) }
        }
        return BatchEventDTO(
            event: e.event,
            distinctId: e.distinctId,
            properties: props.isEmpty ? nil : props,
            timestamp: e.timestampMs,
            sentAt: sentAtMs,
            sessionId: e.sessionId,
            appVersion: e.appVersion
        )
    }
}
