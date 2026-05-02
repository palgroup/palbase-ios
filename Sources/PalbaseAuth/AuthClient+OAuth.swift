import Foundation
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif

extension PalbaseAuth {
    // MARK: - OAuth (web flow)

    /// Get the OAuth authorize URL for the given provider. Open this URL in
    /// `ASWebAuthenticationSession` (or `signInWithOAuth` convenience below) and
    /// extract the callback token.
    public func getOAuthURL(provider: OAuthProvider, redirectTo: String? = nil) async throws(AuthError) -> URL {
        var path = "/auth/oauth/\(provider.name)/authorize"
        if let redirectTo {
            let encoded = redirectTo.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? redirectTo
            path += "?redirect_uri=\(encoded)"
        }

        let dto: OAuthURLResponseDTO
        do {
            dto = try await http.request(method: "GET", path: path, body: nil, headers: [:])
        } catch {
            throw AuthError.from(transport: error)
        }

        guard let url = URL(string: dto.url) else {
            throw AuthError.network(message: "Server returned invalid OAuth URL")
        }
        return url
    }

    // MARK: - Credential exchange (native SDK token → session)

    /// Exchange a provider-issued credential (e.g., Apple ID token, Google ID token)
    /// for a Palbase session.
    ///
    /// Use this when you have a native sign-in SDK that gives you an ID token directly,
    /// avoiding a web round-trip.
    @discardableResult
    public func signIn(provider: OAuthProvider, credential: String, nonce: String? = nil) async throws(AuthError) -> AuthSuccess {
        let dto: AuthResultDTO
        do {
            dto = try await http.request(
                method: "POST",
                path: "/auth/oauth/credential",
                body: CredentialExchangeBody(provider: provider.name, credential: credential, nonce: nonce),
                headers: [:]
            )
        } catch {
            throw AuthError.from(transport: error)
        }

        let session = dto.toSession()
        let user = dto.toUser()
        await tokens.setSession(session)

        return AuthSuccess(user: user, session: session)
    }

    // MARK: - Identities

    /// List all OAuth identities linked to the current user.
    public func listIdentities() async throws(AuthError) -> [Identity] {
        let dto: IdentityListDTO
        do {
            dto = try await http.request(method: "GET", path: "/auth/identities", body: nil, headers: [:])
        } catch {
            throw AuthError.from(transport: error)
        }
        return dto.identities.map { $0.toIdentity() }
    }

    /// Link an OAuth identity to the current user (must be signed in).
    public func linkIdentity(provider: OAuthProvider, credential: String) async throws(AuthError) -> Identity {
        let dto: IdentityDTO
        do {
            dto = try await http.request(
                method: "POST",
                path: "/auth/identities",
                body: LinkIdentityBody(provider: provider.name, credential: credential),
                headers: [:]
            )
        } catch {
            throw AuthError.from(transport: error)
        }
        return dto.toIdentity()
    }

    /// Unlink an OAuth identity from the current user.
    public func unlinkIdentity(id: String) async throws(AuthError) {
        do {
            try await http.requestVoid(
                method: "DELETE",
                path: "/auth/identities/\(id)",
                body: nil,
                headers: [:]
            )
        } catch {
            throw AuthError.from(transport: error)
        }
    }
}

#if canImport(AuthenticationServices) && (os(iOS) || os(macOS) || os(visionOS))

extension PalbaseAuth {
    /// Convenience: launch the OAuth flow in `ASWebAuthenticationSession`,
    /// extract the callback token, and complete sign-in.
    ///
    /// - Parameters:
    ///   - provider: OAuth provider (e.g., `.google`, `.github`)
    ///   - callbackURLScheme: Your app's URL scheme (e.g., `"myapp"` for `myapp://callback`)
    ///   - presentationAnchor: Window for presenting the auth sheet (iOS/macOS)
    /// - Returns: `AuthSuccess` after the user completes sign in
    @MainActor
    public func signInWithOAuth(
        provider: OAuthProvider,
        callbackURLScheme: String,
        presentationAnchor: ASPresentationAnchor
    ) async throws(AuthError) -> AuthSuccess {
        let redirectURI = "\(callbackURLScheme)://oauth-callback"

        let authURL: URL
        do {
            authURL = try await getOAuthURL(provider: provider, redirectTo: redirectURI)
        } catch {
            throw error
        }

        let callbackURL: URL
        do {
            callbackURL = try await launchAuthSession(
                url: authURL,
                callbackScheme: callbackURLScheme,
                anchor: presentationAnchor
            )
        } catch {
            throw AuthError.network(message: "OAuth sign-in cancelled or failed: \(error.localizedDescription)")
        }

        // Extract token / code from callback URL
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let token = components.queryItems?.first(where: { $0.name == "token" || $0.name == "code" })?.value else {
            throw AuthError.network(message: "OAuth callback missing token")
        }

        return try await signIn(provider: provider, credential: token)
    }

    @MainActor
    private func launchAuthSession(url: URL, callbackScheme: String, anchor: ASPresentationAnchor) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme
            ) { callbackURL, error in
                if let callbackURL { continuation.resume(returning: callbackURL) }
                else if let error { continuation.resume(throwing: error) }
                else { continuation.resume(throwing: URLError(.cancelled)) }
            }

            let provider = AuthSessionPresentationProvider(anchor: anchor)
            session.presentationContextProvider = provider
            session.prefersEphemeralWebBrowserSession = false

            // Hold provider for the session's lifetime
            objc_setAssociatedObject(session, &PalbaseAuth.providerKey, provider, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

            session.start()
        }
    }

    nonisolated(unsafe) static var providerKey: UInt8 = 0
}

@MainActor
private final class AuthSessionPresentationProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    let anchor: ASPresentationAnchor
    init(anchor: ASPresentationAnchor) { self.anchor = anchor }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor
    }
}

#endif
