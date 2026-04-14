import Foundation
@_exported import PalbaseCore

/// Transaction handle passed into the `PalbaseDB.transaction { tx in ... }` block.
///
/// Use `tx.from("table")` to issue queries that run inside the transaction.
/// The transaction is committed automatically when the block returns, or
/// rolled back if the block throws.
public struct PalbaseDBTransaction: Sendable {
    let http: HTTPRequesting
    let txId: String

    package init(http: HTTPRequesting, txId: String) {
        self.http = http
        self.txId = txId
    }

    public func from<T: Decodable & Encodable & Sendable>(_ table: String) throws(DBError) -> QueryBuilder<T> {
        try DBValidator.validateTable(table)
        return QueryBuilder<T>(
            http: http,
            table: table,
            basePath: "/v1/db/transaction/\(txId)/query/\(table)"
        )
    }

    public func rpc<P: Encodable & Sendable, R: Decodable & Sendable>(
        _ fnName: String,
        params: P,
        returning: R.Type = R.self
    ) async throws(DBError) -> R {
        try DBValidator.validateFunctionName(fnName)
        let path = "/v1/db/transaction/\(txId)/rpc/\(fnName)"
        do {
            return try await http.request(method: "POST", path: path, body: params, headers: [:])
        } catch {
            throw DBError.from(transport: error)
        }
    }
}
