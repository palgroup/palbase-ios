// Live test fixtures — talks to real Studio tRPC + Kong.
//
// Runs only when STUDIO_BASE is set in the environment. Keeps offline
// `swift test` green; an env-driven gate is the closest equivalent to
// the TS `e2e-live/*.mjs` scripts that the rest of the platform uses.
//
// Test ergonomics:
//   - `Studio` is an actor so cookies + apikey caches stay coherent
//     across the parallel @Test functions in the same project.
//   - `Studio.bootstrap()` does signup + login + project create + apikey
//     reveal. Returns a fresh project handle the suite reuses across
//     individual probes.
//
// All trpc traffic is direct fetch — we don't ship a tRPC SDK in iOS.
// JSON envelope mirrors what `sdk/palbase-ts/e2e-live/phase7-backend-flow.mjs`
// is doing on the JS side.
import Foundation

enum StudioConfig {
    static var baseURL: URL? {
        guard let raw = ProcessInfo.processInfo.environment["STUDIO_BASE"] else {
            return nil
        }
        return URL(string: raw)
    }

    static var enabled: Bool { baseURL != nil }
}

actor Studio {
    let baseURL: URL
    private(set) var cookies: [String: String] = [:]
    private let session: URLSession

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /// One-shot boot: signup + login + project create + apikey reveal.
    /// Returns everything the per-test probes need: ref, anon apikey, etc.
    func bootstrap() async throws -> Project {
        let stamp = Int(Date().timeIntervalSince1970)
        let suffix = String(stamp, radix: 36).suffix(6)
        let ref = "p8\(suffix)"
        let email = "phase8-\(ref)@palbase-loadtest.local"
        let password = "Phase8E2EStrongPassphrase!@#2026-\(stamp)"

        _ = try await trpcPost("auth.signup", body: [
            "email": email,
            "password": password,
            "name": "Phase 8 iOS E2E",
        ])

        _ = try await trpcPost("auth.login", body: [
            "email": email,
            "password": password,
        ])

        guard cookies["palbase.access"] != nil else {
            throw LiveError.bootstrapFailed("login: no palbase.access cookie")
        }

        // Studio auto-creates the user's personal org during signup. Just pick the first.
        let orgs = try await trpcGet("org.list", input: [String: AnyCodable]())
        guard let orgList = orgs.array,
              let firstOrg = orgList.first?.dict,
              let orgId = firstOrg["id"]?.string
        else {
            throw LiveError.bootstrapFailed("no orgs found")
        }

        let createResult = try await trpcPost("project.create", body: [
            "ref": ref,
            "orgId": orgId,
            "name": "Phase 8 \(ref)",
            "tier": "free",
            "region": "northeurope",
        ])
        guard let workflowId = createResult.dict?["workflowId"]?.string else {
            throw LiveError.bootstrapFailed("no workflowId in project.create")
        }

        try await waitForWorkflow(workflowId, deadline: Date().addingTimeInterval(180))

        let revealed = try await trpcGet("apikey.reveal", input: ["ref": AnyCodable(ref)])
        guard let dict = revealed.dict, let anonKey = dict["anonKey"]?.string else {
            throw LiveError.bootstrapFailed("no anon apikey for \(ref)")
        }
        return Project(ref: ref, email: email, password: password, anonKey: anonKey, orgId: orgId)
    }

    /// Block until the workflow Temporal-side reports COMPLETED. Mirrors
    /// the JS probe so we don't probe Studio mid-saga.
    func waitForWorkflow(_ workflowId: String, deadline: Date) async throws {
        while Date() < deadline {
            let status = try await trpcGet("project.status", input: ["workflowId": AnyCodable(workflowId)])
            if let s = status.dict?["status"]?.string, s == "COMPLETED" {
                return
            }
            try await Task.sleep(nanoseconds: 1_500_000_000)
        }
        throw LiveError.bootstrapFailed("workflow \(workflowId) timeout")
    }

    func trpcPost(_ path: String, body: [String: Any]) async throws -> AnyCodable {
        var url = baseURL
        url.appendPathComponent("api/trpc/\(path)")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        attachCookies(to: &req)
        let envelope: [String: Any] = ["json": body]
        req.httpBody = try JSONSerialization.data(withJSONObject: envelope, options: [])

        let (data, resp) = try await session.data(for: req)
        try recordCookies(resp)
        return try parseEnvelope(data, response: resp, path: path)
    }

    func trpcGet(_ path: String, input: [String: AnyCodable]) async throws -> AnyCodable {
        var url = baseURL
        url.appendPathComponent("api/trpc/\(path)")
        let inputJSON = try JSONSerialization.data(withJSONObject: ["json": input.toAny()], options: [])
        let inputStr = String(data: inputJSON, encoding: .utf8) ?? ""
        let escaped = inputStr.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        comps.percentEncodedQuery = "input=\(escaped)"
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        attachCookies(to: &req)

        let (data, resp) = try await session.data(for: req)
        try recordCookies(resp)
        return try parseEnvelope(data, response: resp, path: path)
    }

    private func attachCookies(to req: inout URLRequest) {
        guard !cookies.isEmpty else { return }
        let header = cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
        req.setValue(header, forHTTPHeaderField: "Cookie")
    }

    private func recordCookies(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        // URLSession on Apple platforms folds Set-Cookie into a single
        // comma-joined header. Use HTTPCookie's parser to split safely.
        guard let url = http.url else { return }
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { acc, kv in
            if let k = kv.key as? String, let v = kv.value as? String { acc[k] = v }
        }
        let parsed = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
        for cookie in parsed {
            cookies[cookie.name] = cookie.value
        }
    }

    private func parseEnvelope(_ data: Data, response: URLResponse, path: String) throws -> AnyCodable {
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LiveError.studio("trpc \(path) \(status): non-JSON body")
        }
        if let err = json["error"] as? [String: Any] {
            let msg = ((err["json"] as? [String: Any])?["message"] as? String) ?? "(no message)"
            throw LiveError.studio("trpc \(path) \(status): \(msg)")
        }
        guard status == 200 else {
            throw LiveError.studio("trpc \(path) \(status)")
        }
        // tRPC envelope: { result: { data: { json: <payload> } } }
        let result = json["result"] as? [String: Any]
        let dataField = result?["data"] as? [String: Any]
        let payload: Any = dataField?["json"] ?? dataField ?? json
        return AnyCodable(payload)
    }
}

struct Project: Sendable {
    let ref: String
    let email: String
    let password: String
    let anonKey: String
    let orgId: String

    /// Per-tenant base URL used by PalbaseConfig.url.
    var apiBaseURL: String { "https://\(ref).dev.palbase.studio" }
}

enum LiveError: Error, CustomStringConvertible {
    case bootstrapFailed(String)
    case studio(String)

    var description: String {
        switch self {
        case .bootstrapFailed(let m): return "live bootstrap: \(m)"
        case .studio(let m): return "studio: \(m)"
        }
    }
}

/// Minimal JSON value wrapper so we can poke at trpc responses without
/// declaring a Codable struct for every endpoint we touch.
struct AnyCodable: @unchecked Sendable {
    let value: Any

    init(_ value: Any) { self.value = value }

    var dict: [String: AnyCodable]? {
        (value as? [String: Any]).map { dict in
            dict.mapValues { AnyCodable($0) }
        }
    }

    var array: [AnyCodable]? {
        (value as? [Any]).map { arr in arr.map { AnyCodable($0) } }
    }

    var string: String? { value as? String }
    var int: Int? { value as? Int }
    var bool: Bool? { value as? Bool }
}

extension Dictionary where Key == String, Value == AnyCodable {
    func toAny() -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in self { out[k] = v.value }
        return out
    }
}
