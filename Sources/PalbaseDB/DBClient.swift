import Foundation
@_exported import PalbaseCore

/// Palbase DB module entry point. Use `PalbaseDB.shared` after `Palbase.configure(_:)`.
///
/// ```swift
/// struct Todo: Codable, Sendable { let id: String; let title: String; let done: Bool }
///
/// let todos: [Todo] = try await PalbaseDB.shared
///     .from("todos")
///     .select()
///     .eq("done", false)
///     .order("created_at", ascending: false)
///     .limit(50)
///     .execute()
/// ```
public struct PalbaseDB: Sendable {
    let http: HTTPRequesting
    let tokens: TokenManager
    let pathPrefix: String

    package init(http: HTTPRequesting, tokens: TokenManager, pathPrefix: String = "/v1/db") {
        self.http = http
        self.tokens = tokens
        self.pathPrefix = pathPrefix
    }

    /// Shared DB client backed by the global SDK configuration.
    /// Throws `DBError.notConfigured` if `Palbase.configure(_:)` was not called.
    public static var shared: PalbaseDB {
        get throws(DBError) {
            guard let http = Palbase.http, let tokens = Palbase.tokens else {
                throw DBError.notConfigured
            }
            return PalbaseDB(http: http, tokens: tokens)
        }
    }

    // MARK: - Query entry

    /// Build a query against `table`. Returns a chainable `QueryBuilder<T>`.
    ///
    /// Throws `DBError.invalidTable` if the table name is not a valid
    /// PostgREST identifier.
    public func from<T: Decodable & Encodable & Sendable>(_ table: String) throws(DBError) -> QueryBuilder<T> {
        try DBValidator.validateTable(table)
        return QueryBuilder<T>(
            http: http,
            table: table,
            basePath: "\(pathPrefix)/\(table)"
        )
    }

    // MARK: - RPC

    /// Call a PostgREST RPC function with the given parameters and decode the response.
    public func rpc<P: Encodable & Sendable, R: Decodable & Sendable>(
        _ fnName: String,
        params: P,
        returning: R.Type = R.self
    ) async throws(DBError) -> R {
        try DBValidator.validateFunctionName(fnName)
        do {
            return try await http.request(
                method: "POST",
                path: "\(pathPrefix)/rpc/\(fnName)",
                body: params,
                headers: [:]
            )
        } catch {
            throw DBError.from(transport: error)
        }
    }

    /// Call an RPC function with no parameters.
    public func rpc<R: Decodable & Sendable>(
        _ fnName: String,
        returning: R.Type = R.self
    ) async throws(DBError) -> R {
        try DBValidator.validateFunctionName(fnName)
        do {
            let body: AnyEncodable? = nil
            return try await http.request(
                method: "POST",
                path: "\(pathPrefix)/rpc/\(fnName)",
                body: body,
                headers: [:]
            )
        } catch {
            throw DBError.from(transport: error)
        }
    }

    // MARK: - Transaction

    /// Execute `block` inside a DB transaction. The transaction is committed
    /// when the block returns, or rolled back if it throws. Default timeout 30s.
    public func transaction(
        timeout: TimeInterval = 30,
        _ block: @Sendable @escaping (PalbaseDBTransaction) async throws -> Void
    ) async throws(DBError) {
        // Begin
        let begin: TransactionBeginResponse
        do {
            begin = try await http.request(
                method: "POST",
                path: "\(pathPrefix)/transaction/begin",
                body: nil,
                headers: [:]
            )
        } catch {
            throw DBError.from(transport: error)
        }

        try DBValidator.validateTransactionId(begin.txId)
        let txId = begin.txId
        let tx = PalbaseDBTransaction(http: http, txId: txId)
        let pathPrefix = self.pathPrefix
        let httpRef = http

        // Run block with a timeout.
        let result: Result<Void, any Error & Sendable> = await withTaskGroup(
            of: Result<Void, any Error & Sendable>.self
        ) { group in
            group.addTask {
                do {
                    try await block(tx)
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }
            group.addTask {
                let nanos = UInt64(max(timeout, 0) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                return .failure(DBError.transactionTimeout)
            }
            guard let first = await group.next() else {
                group.cancelAll()
                return .failure(DBError.transactionFailed("No result"))
            }
            group.cancelAll()
            return first
        }

        switch result {
        case .success:
            // Commit
            do {
                try await httpRef.requestVoid(
                    method: "POST",
                    path: "\(pathPrefix)/transaction/\(txId)/commit",
                    body: nil,
                    headers: [:]
                )
            } catch {
                // Best-effort rollback.
                try? await httpRef.requestVoid(
                    method: "POST",
                    path: "\(pathPrefix)/transaction/\(txId)/rollback",
                    body: nil,
                    headers: [:]
                )
                throw DBError.from(transport: error)
            }

        case .failure(let err):
            // Roll back, but propagate the original error.
            try? await httpRef.requestVoid(
                method: "POST",
                path: "\(pathPrefix)/transaction/\(txId)/rollback",
                body: nil,
                headers: [:]
            )
            if let dbErr = err as? DBError { throw dbErr }
            if let core = err as? PalbaseCoreError {
                throw DBError.from(transport: core)
            }
            throw DBError.transactionFailed(err.localizedDescription)
        }
    }
}
