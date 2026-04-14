# PalbaseDocs

Firestore-like document API for Palbase — hierarchical collections and
documents backed by PostgreSQL JSONB on the server.

- Document / collection refs (typed on your `Codable` model)
- Chainable queries with cursor pagination
- Atomic field transforms (`increment`, `arrayUnion`, `serverTimestamp`, ...)
- Aggregations (`count`, `sum`, `avg`, `min`, `max`)
- Batch writes, batch reads
- Server-side transactions (read-then-write)
- Collection group queries across nested subcollections
- Live query listeners via server-sent events

## Setup

```swift
import PalbaseDocs

Palbase.configure(apiKey: "pb_abc123_xxx")
let docs = try PalbaseDocs.shared
```

Define a `Codable & Sendable` model for each collection:

```swift
struct User: Codable, Sendable {
    let id: String
    let name: String
    let age: Int
    let status: String
}
```

## Refs

```swift
let users    = try docs.collection("users", of: User.self)
let userRef  = try users.document("u1")                       // DocumentRef<User>
let posts    = try userRef.collection("posts", of: Post.self) // subcollection
let postRef  = try posts.document("p1")

// Typed at the module level, too:
let direct: DocumentRef<User> = try docs.document("users/u1")
```

`DocumentRef` paths have an even number of segments (`users/u1`,
`users/u1/posts/p1`). `CollectionRef` paths have an odd number
(`users`, `users/u1/posts`).

## Reads & writes

```swift
// Create / overwrite
try await userRef.set(User(id: "u1", name: "Salih", age: 30, status: "active"))

// Create with server-assigned ID
let newRef = try await users.add(User(id: "", name: "New", age: 1, status: "active"))

// Shallow merge
try await userRef.set(someUser, merge: true)

// Partial update (dot notation — fails with documentNotFound if absent)
try await userRef.update([
    "name": .string("Salih K"),
    "nested.city": .string("Istanbul")
])

// Get
let snap = try await userRef.get()
if snap.exists, let user = snap.data() {
    print(user.name)
}

// Delete (optionally cascade subcollections)
try await userRef.delete()
try await userRef.delete(recursive: true)
```

## Queries

```swift
let snap = try await users
    .where("age", .greaterThan, .int(18))
    .where("status", .equalTo, .string("active"))
    .orderBy("name", ascending: true)
    .limit(50)
    .get()

for doc in snap.docs {
    print(doc.id, doc.data()?.name ?? "?")
}
```

### Operators

| Swift case | Server op |
|--|--|
| `.equalTo` | `==` |
| `.notEqualTo` | `!=` |
| `.lessThan` / `.lessThanOrEqual` | `<` / `<=` |
| `.greaterThan` / `.greaterThanOrEqual` | `>` / `>=` |
| `.in` / `.notIn` | `in` / `not-in` |
| `.arrayContains` / `.arrayContainsAny` | `array-contains` / `array-contains-any` |
| `.isNull` / `.isNotNull` | `is-null` / `is-not-null` |

## Cursor pagination

```swift
let page1 = try await users.orderBy("created_at").limit(20).get()

if let last = page1.docs.last, let created = last.rawData() {
    let page2 = try await users
        .orderBy("created_at")
        .startAfter([created])
        .limit(20)
        .get()
}
```

`startAt`, `startAfter`, `endAt`, `endBefore` are all supported. Pass one
`JSONValue` per `orderBy` field.

## Aggregations

```swift
let count = try await users
    .where("status", .equalTo, .string("active"))
    .count()

let report = try await orders.aggregate([
    .count(alias: "total"),
    .sum(field: "amount"),
    .avg(field: "amount"),
    .min(field: "amount"),
    .max(field: "amount")
])
print(report.int("total"), report.double("sum_amount"))
```

## Field transforms

```swift
try await userRef.transform([
    .increment(field: "views", by: 1),
    .arrayUnion(field: "tags", values: [.string("featured")]),
    .arrayRemove(field: "tags", values: [.string("old")]),
    .serverTimestamp(field: "updated_at"),
    .maximum(field: "high_score", value: 100),
    .minimum(field: "low_score", value: 0)
])
```

Up to 20 transforms per call.

## Batch writes

```swift
let a = try users.document("a")
let b = try users.document("b")
let c = try users.document("c")

try await docs.batch([
    .set(ref: a, data: userA),
    .update(ref: b, data: ["name": .string("B!")]),
    .delete(ref: c),
    .transform(ref: a, transforms: [.increment(field: "views", by: 1)])
])
```

Max 500 operations per batch; all apply atomically in a single server
transaction.

## Batch get

```swift
let snaps = try await docs.batchGet([
    try users.document("a"),
    try users.document("b"),
    try users.document("missing")
])
// snaps.count == 3. Missing refs return exists == false.
```

## Transactions (read-then-write)

```swift
try await docs.transaction { tx in
    let snap = try await tx.get(userRef)
    let current = snap.data()?.age ?? 0
    try tx.update(userRef, data: ["age": .int(Int64(current + 1))])
}
```

Reads within a transaction see a consistent snapshot; queued writes are
applied atomically on successful return. A thrown error triggers rollback.

## Collection group queries

Query across every subcollection with the same ID, regardless of parent path:

```swift
let allReviews = try await docs.collectionGroup("reviews", of: Review.self)
    .where("rating", .greaterThanOrEqual, .int(4))
    .get()
```

## Listing subcollection IDs

```swift
let names = try await userRef.listCollectionIds()
// e.g. ["posts", "comments"]
```

## Live listeners

```swift
let unsubscribe = await users
    .where("status", .equalTo, .string("active"))
    .onSnapshot { [weak self] snap in
        for change in snap.docChanges {
            switch change.type {
            case .added:    self?.onAdded(change.document)
            case .modified: self?.onModified(change.document)
            case .removed:  self?.onRemoved(change.document)
            }
        }
    }

// Later:
unsubscribe()
```

> Warning: `onSnapshot`'s closure escapes. Capture `self` weakly to avoid
> retain cycles.

Under the hood: the SDK `POST`s to `/subscribe` to open a server-sent event
stream, drains events, and issues `DELETE /subscriptions/{id}` on
`unsubscribe()`.

## Error handling

```swift
do {
    try await userRef.get()
} catch DocsError.documentNotFound(let path) {
    print("missing:", path)
} catch DocsError.notConfigured {
    fatalError("Call Palbase.configure(apiKey:) first")
} catch {
    print(error.localizedDescription)
}
```

### `DocsError` cases

| Case | When |
|--|--|
| `.notConfigured` | `Palbase.configure(_:)` not called |
| `.invalidPath(String)` | Path segment is invalid (`..`, empty, bad chars) |
| `.invalidFieldName(String)` | Field name contains disallowed characters |
| `.batchTooLarge(max:)` | Batch > 500 operations |
| `.transformsTooLarge(max:)` | > 20 transforms in a single request |
| `.documentNotFound(path:)` | Server returned 404 for the document |
| `.transactionTimeout` | Transaction exceeded its deadline |
| `.transactionFailed(String)` | Transaction closure threw, commit/rollback failed |
| `.streamingUnsupported` | Underlying transport does not implement SSE |
| `.network(String)` | Transport-level failure |
| `.encoding(String)` / `.decoding(String)` | Codec failure |
| `.rateLimited(retryAfter:)` | HTTP 429 |
| `.serverError(status:message:)` | 5xx |
| `.http(status:code:message:requestId:)` | Other HTTP error with envelope |
| `.server(code:message:requestId:)` | Palbase server-envelope error |

## Public types

| Type | Purpose |
|--|--|
| `PalbaseDocs` | Module entrypoint — `collection`, `collectionGroup`, `batch`, `batchGet`, `transaction` |
| `CollectionRef<T>` | Collection reference — `document`, `add`, `where`, `orderBy`, `limit`, `count`, `aggregate` |
| `DocumentRef<T>` | Document reference — `get`, `set`, `update`, `delete`, `transform`, `collection`, `listCollectionIds` |
| `Query<T>` | Chainable query — `where`, `orderBy`, `limit`, cursor methods, `get`, `count`, `aggregate`, `onSnapshot` |
| `DocumentSnapshot<T>` | Single-doc result — `id`, `path`, `exists`, `data()`, `rawData()`, `version`, `ref` |
| `QuerySnapshot<T>` | Query result — `docs`, `docChanges`, `size`, `empty` |
| `DocumentChange<T>` | Individual change emitted by `onSnapshot` — `type`, `document` |
| `ChangeType` | `.added`, `.modified`, `.removed` |
| `WhereOperator` | Query operator enum |
| `FieldTransform` | Transform enum — `.increment`, `.arrayUnion`, `.serverTimestamp`, … |
| `Aggregate` / `AggregateResult` | Aggregation spec + result |
| `BatchOperation<T>` | `.set`, `.setMerge`, `.update`, `.delete`, `.transform` |
| `PalbaseDocsTransaction` | Transaction handle — `get`, `set`, `update`, `delete`, `transform` |
| `JSONValue` | Untyped JSON value used in query values, cursors, update maps |
| `DocsError` | Typed error enum conforming to `PalbaseError` |

## Limits

| Limit | Value |
|--|--|
| Max batch / transaction operations | 500 |
| Max transforms per request | 20 |
| Max document size | 1 MiB (enforced server-side) |

## Testing

The module ships with `Tests/PalbaseDocsTests/DocsTests.swift` (Swift Testing).
All layers are exercised with a mock `HTTPRequesting`: path validation,
query body construction, cursor encoding, transform / batch / batchGet
payloads, transaction commit/rollback, SSE listener lifecycle, and the
full `PalbaseCoreError` → `DocsError` mapping.

Run locally:

```bash
swift test --filter PalbaseDocsTests
```
