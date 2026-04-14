import Foundation
#if canImport(AuthenticationServices) && (os(iOS) || os(macOS) || os(visionOS))
import AuthenticationServices
import CryptoKit

extension PalbaseAuth {
    /// Native Apple Sign In. Presents the system sheet, returns Apple's identity token,
    /// and exchanges it with the Palbase backend for a session.
    ///
    /// Make sure the **"Sign in with Apple"** capability is enabled in your target.
    ///
    /// ```swift
    /// // From a SwiftUI button:
    /// let result = try await PalbaseAuth.shared.signInWithApple()
    /// ```
    ///
    /// - Parameter scopes: Requested scopes (default: email + fullName).
    /// - Returns: `AuthSuccess` after Apple authenticates and Palbase issues a session.
    @MainActor
    @discardableResult
    public func signInWithApple(
        scopes: [ASAuthorization.Scope] = [.email, .fullName]
    ) async throws(AuthError) -> AuthSuccess {
        let nonce = Self.generateNonce()
        let hashedNonce = Self.sha256(nonce)

        let credential: ASAuthorizationAppleIDCredential
        do {
            credential = try await Self.requestAppleSignIn(scopes: scopes, hashedNonce: hashedNonce)
        } catch let error as ASAuthorizationError where error.code == .canceled {
            throw AuthError.invalidCredentials(message: "Sign in with Apple was cancelled")
        } catch {
            throw AuthError.network(message: "Apple Sign In failed: \(error.localizedDescription)")
        }

        guard let identityTokenData = credential.identityToken,
              let identityToken = String(data: identityTokenData, encoding: .utf8) else {
            throw AuthError.invalidCredentials(message: "Apple did not return an identity token")
        }

        return try await signIn(provider: .apple, credential: identityToken, nonce: nonce)
    }

    @MainActor
    private static func requestAppleSignIn(
        scopes: [ASAuthorization.Scope],
        hashedNonce: String
    ) async throws -> ASAuthorizationAppleIDCredential {
        try await withCheckedThrowingContinuation { continuation in
            let provider = ASAuthorizationAppleIDProvider()
            let request = provider.createRequest()
            request.requestedScopes = scopes
            request.nonce = hashedNonce

            let delegate = AppleSignInDelegate(continuation: continuation)
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = delegate
            controller.presentationContextProvider = delegate

            // Hold delegate for controller lifetime
            objc_setAssociatedObject(controller, &PalbaseAuth.appleSignInDelegateKey, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

            controller.performRequests()
        }
    }

    nonisolated(unsafe) static var appleSignInDelegateKey: UInt8 = 0

    // MARK: - Nonce generation (recommended for replay protection)

    private static func generateNonce(length: Int = 32) -> String {
        precondition(length > 0)
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remaining = length
        while remaining > 0 {
            let randoms: [UInt8] = (0..<16).map { _ in UInt8.random(in: 0...UInt8.max) }
            for random in randoms {
                if remaining == 0 { break }
                if random < charset.count {
                    result.append(charset[Int(random) % charset.count])
                    remaining -= 1
                }
            }
        }
        return result
    }

    private static func sha256(_ input: String) -> String {
        let data = Data(input.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
private final class AppleSignInDelegate: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    let continuation: CheckedContinuation<ASAuthorizationAppleIDCredential, Error>

    init(continuation: CheckedContinuation<ASAuthorizationAppleIDCredential, Error>) {
        self.continuation = continuation
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        if let cred = authorization.credential as? ASAuthorizationAppleIDCredential {
            continuation.resume(returning: cred)
        } else {
            continuation.resume(throwing: ASAuthorizationError(.failed))
        }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        continuation.resume(throwing: error)
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        #if os(iOS) || os(visionOS)
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
        #else
        ASPresentationAnchor()
        #endif
    }
}

#if os(iOS) || os(visionOS)
import UIKit
#endif

#endif
