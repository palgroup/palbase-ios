import Foundation
@_exported import PalbaseCore

/// Per-user inbox client. The authenticated user's iJWT is attached
/// automatically by HttpClient + TokenManager; the server's
/// SET LOCAL ROLE chain enforces RLS so each user only sees their own
/// rows.
public struct InboxClient: Sendable {
    private let http: HTTPRequesting
    private let pathPrefix: String

    package init(http: HTTPRequesting, pathPrefix: String) {
        self.http = http
        self.pathPrefix = pathPrefix
    }

    /// List the authenticated user's inbox messages, paginated.
    public func list(
        _ options: InboxListOptions = InboxListOptions()
    ) async throws(NotificationsError) -> InboxListResult {
        var components = URLComponents()
        var items: [URLQueryItem] = []
        if let c = options.cursor { items.append(URLQueryItem(name: "cursor", value: c)) }
        if let l = options.limit { items.append(URLQueryItem(name: "limit", value: String(l))) }
        if let r = options.isRead { items.append(URLQueryItem(name: "is_read", value: r ? "true" : "false")) }
        if let cat = options.category { items.append(URLQueryItem(name: "category", value: cat)) }
        if options.includeArchived {
            items.append(URLQueryItem(name: "include_archived", value: "true"))
        }
        components.queryItems = items.isEmpty ? nil : items
        let query = components.percentEncodedQuery.map { "?\($0)" } ?? ""
        do {
            return try await http.request(
                method: "GET",
                path: "\(pathPrefix)/inbox\(query)",
                body: nil,
                headers: [:]
            )
        } catch let err {
            throw NotificationsError.from(transport: err)
        }
    }

    /// Count unread, non-archived messages for the authenticated user.
    public func unreadCount() async throws(NotificationsError) -> Int {
        do {
            let resp: InboxUnreadCount = try await http.request(
                method: "GET",
                path: "\(pathPrefix)/inbox/unread-count",
                body: nil,
                headers: [:]
            )
            return resp.count
        } catch let err {
            throw NotificationsError.from(transport: err)
        }
    }

    /// Mark one message read.
    public func markRead(id: String) async throws(NotificationsError) {
        let encoded = id.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? id
        do {
            try await http.requestVoid(
                method: "PATCH",
                path: "\(pathPrefix)/inbox/\(encoded)/read",
                body: nil,
                headers: [:]
            )
        } catch let err {
            throw NotificationsError.from(transport: err)
        }
    }

    /// Mark every unread message read for the current user.
    public func markAllRead() async throws(NotificationsError) {
        do {
            try await http.requestVoid(
                method: "POST",
                path: "\(pathPrefix)/inbox/read-all",
                body: nil,
                headers: [:]
            )
        } catch let err {
            throw NotificationsError.from(transport: err)
        }
    }

    /// Archive (soft delete) one message.
    public func archive(id: String) async throws(NotificationsError) {
        let encoded = id.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? id
        do {
            try await http.requestVoid(
                method: "DELETE",
                path: "\(pathPrefix)/inbox/\(encoded)",
                body: nil,
                headers: [:]
            )
        } catch let err {
            throw NotificationsError.from(transport: err)
        }
    }
}
