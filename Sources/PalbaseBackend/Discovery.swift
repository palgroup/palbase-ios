import Foundation
@_exported import PalbaseCore

#if DEBUG
import Network

/// Bonjour discovery for `_palbase._tcp` services advertised by
/// `palbase backend dev`. Returns the first matching service's URL or
/// `nil` after `timeout`. Filters by TXT record `ref` when provided so
/// multiple developers on the same Wi-Fi don't cross-connect.
///
/// Compiled into DEBUG builds only — Release skips the Bonjour code
/// path entirely so the App Store / TestFlight binary never browses
/// the local network and never triggers
/// `NSLocalNetworkUsageDescription` prompts.
package enum BonjourDiscovery {
    package static let serviceType = "_palbase._tcp"
    package static let defaultTimeout: TimeInterval = 1.5

    /// Browse for `_palbase._tcp` services. The first endpoint whose
    /// TXT `ref` matches `expectedRef` (or any service if expectedRef
    /// is nil) is resolved to a base URL.
    package static func discover(
        expectedRef: String?,
        timeout: TimeInterval = defaultTimeout,
        queue: DispatchQueue = .global(qos: .userInitiated)
    ) async -> URL? {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true

        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: serviceType, domain: nil),
            using: parameters
        )

        return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            // Continuation guarded by an actor — Bonjour callbacks fire
            // from the dispatch queue and we only want one resume.
            let resumer = ResumeOnce(continuation: continuation)

            browser.browseResultsChangedHandler = { results, _ in
                for result in results {
                    guard case let .service(name, _, _, _) = result.endpoint else { continue }
                    var matched = true
                    if let expectedRef {
                        matched = false
                        if case let .bonjour(record) = result.metadata {
                            if let entry = record.dictionary["ref"], entry == expectedRef {
                                matched = true
                            }
                        }
                    }
                    guard matched else { continue }
                    Self.resolve(endpoint: result.endpoint, fallbackName: name, queue: queue) { url in
                        if let url {
                            resumer.fire(with: url)
                            browser.cancel()
                        }
                    }
                }
            }

            browser.stateUpdateHandler = { state in
                switch state {
                case .failed, .cancelled:
                    resumer.fire(with: nil)
                default:
                    break
                }
            }

            browser.start(queue: queue)

            // Hard deadline — discovery is best-effort, never block forever.
            queue.asyncAfter(deadline: .now() + timeout) {
                resumer.fire(with: nil)
                browser.cancel()
            }
        }
    }

    /// Resolve a Bonjour endpoint to a concrete `http://host:port` URL.
    /// We open an `NWConnection` with the matched endpoint and read
    /// its `currentPath` — this is the documented way to extract IP
    /// + port from a resolved bonjour service in 2026.
    private static func resolve(
        endpoint: NWEndpoint,
        fallbackName: String,
        queue: DispatchQueue,
        completion: @escaping @Sendable (URL?) -> Void
    ) {
        let conn = NWConnection(to: endpoint, using: .tcp)
        let resumer = ResumeOnceURL(completion: completion)
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                guard let inner = conn.currentPath?.remoteEndpoint else {
                    resumer.fire(with: nil)
                    conn.cancel()
                    return
                }
                if case let .hostPort(host, port) = inner {
                    let hostString = hostString(from: host)
                    let url = URL(string: "http://\(hostString):\(port.rawValue)")
                    resumer.fire(with: url)
                } else {
                    resumer.fire(with: nil)
                }
                conn.cancel()
            case .failed, .cancelled:
                resumer.fire(with: nil)
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private static func hostString(from host: NWEndpoint.Host) -> String {
        switch host {
        case .name(let name, _): return name
        case .ipv4(let addr): return "\(addr)"
        case .ipv6(let addr): return "[\(addr)]"
        @unknown default: return "localhost"
        }
    }
}

/// Single-shot resume guard. Bonjour can call back multiple times;
/// `CheckedContinuation` panics if resumed twice.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private let continuation: CheckedContinuation<URL?, Never>

    init(continuation: CheckedContinuation<URL?, Never>) {
        self.continuation = continuation
    }

    func fire(with url: URL?) {
        lock.lock()
        defer { lock.unlock() }
        guard !fired else { return }
        fired = true
        continuation.resume(returning: url)
    }
}

private final class ResumeOnceURL: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private let completion: @Sendable (URL?) -> Void

    init(completion: @escaping @Sendable (URL?) -> Void) {
        self.completion = completion
    }

    func fire(with url: URL?) {
        lock.lock()
        defer { lock.unlock() }
        guard !fired else { return }
        fired = true
        completion(url)
    }
}
#endif
