import Foundation

/// Starts a subscription — emits `QuerySnapshot` updates until unsubscribed.
///
/// > Warning: Escaping callbacks should capture `self` weakly to avoid retain
/// > cycles:
/// > ```swift
/// > let unsub = await query.onSnapshot { [weak self] snap in
/// >     self?.handle(snap)
/// > }
/// > ```
enum SnapshotListener {
    static func start<T: Codable & Sendable>(
        query: Query<T>,
        callback: @escaping @Sendable (QuerySnapshot<T>) -> Void
    ) async -> Unsubscribe {
        let state = ListenerState()
        let transport = query.transport
        let subscribePath = query.subscribePath()
        let pathPrefix = query.rawPathPrefix
        let body = query.buildSubscribeBody()

        // Kick off the initial subscribe + streaming task.
        let task = Task {
            await runLoop(
                transport: transport,
                subscribePath: subscribePath,
                pathPrefix: pathPrefix,
                body: body,
                query: query,
                callback: callback,
                state: state
            )
        }
        await state.setTask(task)

        return {
            Task { await state.stop(transport: transport, pathPrefix: pathPrefix) }
        }
    }

    private static func runLoop<T: Codable & Sendable>(
        transport: HTTPRequesting,
        subscribePath: String,
        pathPrefix: String,
        body: SubscribeRequestBody,
        query: Query<T>,
        callback: @escaping @Sendable (QuerySnapshot<T>) -> Void,
        state: ListenerState
    ) async {
        // POST /subscribe → {subscriptionId, documents, streamUrl}
        let resp: SubscribeResponseDTO
        do {
            resp = try await transport.request(
                method: "POST",
                path: subscribePath,
                body: body,
                headers: [:]
            )
        } catch {
            return
        }

        await state.setSubscriptionId(resp.subscriptionId)
        if await state.isStopped() { return }

        // Emit initial snapshot from POST response.
        let initialDocs = (resp.documents ?? []).map { dto in
            DocumentSnapshot<T>(
                id: dto.documentId,
                path: dto.path,
                exists: true,
                version: dto.version,
                raw: dto.data,
                ref: DocumentRef<T>(http: transport, pathPrefix: pathPrefix, path: dto.path)
            )
        }
        let initial = QuerySnapshot(
            docs: initialDocs,
            docChanges: initialDocs.map { DocumentChange(type: .added, document: $0) }
        )
        callback(initial)

        // Drain the SSE stream.
        let streamPath = "\(pathPrefix)/subscriptions/\(resp.subscriptionId)/stream"
        do {
            let events = try await transport.streamServerSentEvents(path: streamPath)
            for try await event in events {
                if await state.isStopped() { break }
                guard let change = try? decodeEvent(event, transport: transport, pathPrefix: pathPrefix, as: T.self) else {
                    continue
                }
                let snap = QuerySnapshot<T>(docs: [change.document], docChanges: [change])
                callback(snap)
            }
        } catch {
            // Stream ended (server closed / network). Caller can resubscribe.
        }
    }

    private static func decodeEvent<T: Codable & Sendable>(
        _ event: SSEEvent,
        transport: HTTPRequesting,
        pathPrefix: String,
        as: T.Type
    ) throws -> DocumentChange<T>? {
        guard let data = event.data.data(using: .utf8) else { return nil }
        let parsed = try JSONDecoder.palbaseDefault.decode(SSEEventDTO.self, from: data)
        let type: ChangeType
        switch parsed.type {
        case "added": type = .added
        case "modified": type = .modified
        case "removed": type = .removed
        default: return nil
        }
        guard let path = parsed.path else { return nil }
        let ref = DocumentRef<T>(http: transport, pathPrefix: pathPrefix, path: path)
        let doc = DocumentSnapshot<T>(
            id: String(path.split(separator: "/").last ?? ""),
            path: path,
            exists: type != .removed,
            version: 0,
            raw: parsed.document,
            ref: ref
        )
        return DocumentChange(type: type, document: doc)
    }
}

/// Shared state for a running snapshot listener.
actor ListenerState {
    private var stopped = false
    private var task: Task<Void, Never>?
    private var subscriptionId: String?

    func setTask(_ t: Task<Void, Never>) { self.task = t }
    func setSubscriptionId(_ id: String) { self.subscriptionId = id }
    func isStopped() -> Bool { stopped }

    func stop(transport: HTTPRequesting, pathPrefix: String) async {
        if stopped { return }
        stopped = true
        task?.cancel()
        if let id = subscriptionId {
            try? await transport.requestVoid(
                method: "DELETE",
                path: "\(pathPrefix)/subscriptions/\(id)",
                body: nil,
                headers: [:]
            )
        }
    }
}

// MARK: - SSE transport

/// Represents a single parsed SSE event.
struct SSEEvent: Sendable {
    let event: String
    let data: String
}

extension HTTPRequesting {
    /// Open a long-lived GET connection and yield parsed SSE events. The
    /// stream ends when the server closes the connection or the task is
    /// cancelled. Default implementation on the protocol falls through to the
    /// concrete client; tests can override by conforming to a richer protocol.
    func streamServerSentEvents(path: String) async throws -> AsyncThrowingStream<SSEEvent, Error> {
        if let streamer = self as? SSEStreaming {
            return try await streamer.streamSSE(path: path)
        }
        throw DocsError.streamingUnsupported
    }
}

/// Optional capability: transports that support SSE implement this. Tests can
/// inject a mock conforming to it.
protocol SSEStreaming: HTTPRequesting {
    func streamSSE(path: String) async throws -> AsyncThrowingStream<SSEEvent, Error>
}
