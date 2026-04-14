# PalbaseDB

Relational database module for Palbase (PostgREST-backed). Typed queries, mutations,
RPC, and transactions over a chainable `QueryBuilder`.

## Setup

```swift
import PalbaseDB

@main
struct MyApp: App {
    init() { Palbase.configure(apiKey: "pb_abc123_xxx") }
    var body: some Scene { ... }
}
```

`PalbaseDB` re-exports `PalbaseCore`, so `import PalbaseDB` is enough.

## Define a Codable model

```swift
struct Todo: Codable, Sendable {
    let id: String
    let title: String
    let done: Bool
    let createdAt: Date
}
```

JSON keys are automatically converted to/from `snake_case` (`createdAt` ↔ `created_at`).

## Select

```swift
// All rows
let todos: [Todo] = try await PalbaseDB.shared
    .from("todos")
    .select()
    .execute()

// With filters, ordering, pagination
let recent: [Todo] = try await PalbaseDB.shared
    .from("todos")
    .select("id,title,done")
    .eq("done", false)
    .order("created_at", ascending: false)
    .limit(20)
    .execute()

// Range (offset pagination)
let page2: [Todo] = try await PalbaseDB.shared
    .from("todos")
    .select()
    .range(from: 20, to: 39)
    .execute()
```

## Single row

```swift
// Exactly one row — throws if 0 rows match
let todo: Todo = try await PalbaseDB.shared
    .from("todos")
    .select()
    .eq("id", "t_abc")
    .single()
    .execute()

// Zero-or-one
let maybe: Todo? = try await PalbaseDB.shared
    .from("todos")
    .select()
    .eq("id", "t_abc")
    .maybeSingle()
    .execute()
```

## Filters

```swift
try qb.eq("status", "open")
try qb.neq("status", "archived")
try qb.gt("priority", 3)
try qb.gte("priority", 3)
try qb.lt("priority", 3)
try qb.lte("priority", 3)
try qb.like("title", "foo%")
try qb.ilike("title", "%BAR%")
try qb.in_("id", values: ["a", "b", "c"])
try qb.is_("archived_at", "null")
```

## Insert

```swift
let created: [Todo] = try await PalbaseDB.shared
    .from("todos")
    .insert(Todo(id: "t1", title: "buy milk", done: false, createdAt: Date()))
    .execute()
```

## Update

```swift
struct TodoPatch: Encodable, Sendable { let done: Bool }

_ = try await PalbaseDB.shared
    .from("todos")
    .update(TodoPatch(done: true))
    .eq("id", "t1")
    .execute()
```

## Upsert

```swift
_ = try await PalbaseDB.shared
    .from("todos")
    .upsert(Todo(id: "t1", title: "x", done: false, createdAt: Date()))
    .execute()
```

## Delete

```swift
_ = try await PalbaseDB.shared
    .from("todos")
    .delete()
    .eq("id", "t1")
    .execute()
```

## RPC

```swift
struct Params: Encodable, Sendable { let userId: String }
struct Count: Decodable, Sendable { let count: Int }

let result: Count = try await PalbaseDB.shared.rpc(
    "count_open_todos",
    params: Params(userId: "u1")
)

// No-params form
let ping: String = try await PalbaseDB.shared.rpc("server_time")
```

## Transactions

```swift
try await PalbaseDB.shared.transaction { tx in
    let qb1: QueryBuilder<Todo> = try tx.from("todos")
    _ = try await qb1.insert(newTodo).execute()

    let qb2: QueryBuilder<User> = try tx.from("users")
    _ = try await qb2.update(patch).eq("id", userId).execute()
}
// Auto-commits on return, auto-rollbacks on throw.
// Default timeout 30s — override via `.transaction(timeout: 10) { ... }`.
```

## Error Handling

All public methods `throws(DBError)`:

```swift
do {
    let _: [Todo] = try await PalbaseDB.shared.from("todos").select().execute()
} catch DBError.notConfigured {
    fatalError("Call Palbase.configure(apiKey:) first")
} catch DBError.rateLimited(let retryAfter) {
    // Back off
} catch DBError.transactionTimeout {
    // Retry the transaction
} catch {
    print(error.localizedDescription)
}
```

### `DBError` cases

| Case | When |
|------|------|
| `.notConfigured` | `Palbase.configure(_:)` not called |
| `.invalidTable(String)` | Table name fails validation |
| `.invalidColumn(String)` | Column name fails validation |
| `.invalidFunctionName(String)` | RPC function name fails validation |
| `.invalidTransactionId(String)` | Server returned a malformed tx id |
| `.transactionTimeout` | Transaction exceeded its timeout |
| `.transactionFailed(String)` | Block threw a non-DB error |
| `.network(String)` | Transport failure |
| `.decoding(String)` | Server response could not be decoded |
| `.rateLimited(retryAfter: Int?)` | 429 |
| `.serverError(status, message)` | 5xx |
| `.http(status, code, message, requestId)` | Other HTTP error |
| `.server(code, message, requestId)` | Unrecognized server error envelope |

## Public Types

| Type | Purpose |
|------|---------|
| `PalbaseDB` | Module entry — `PalbaseDB.shared` |
| `DBError` | All errors thrown by PalbaseDB |
| `QueryBuilder<T>` | Chainable builder returned by `.from(_:)` |
| `SingleQueryBuilder<T>` | Single-row variant returned by `.single()` |
| `MaybeSingleQueryBuilder<T>` | Zero-or-one variant returned by `.maybeSingle()` |
| `PalbaseDBTransaction` | Handle passed into `.transaction { tx in … }` |
| `JSONValue` | JSON-encodable value for dynamic `rpc` params |

## TODO

- [ ] GraphQL / relational selection (`select("id, author(name)")`)
- [ ] Admin client (`admin.tables`, `admin.schemas`, `admin.columns`)
- [ ] Abort signal / Task cancellation propagation
