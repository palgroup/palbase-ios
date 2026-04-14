import Foundation

extension PalbaseAuth {
    // MARK: - Trusted Devices

    /// List trusted devices for the current user.
    public func listTrustedDevices() async throws(AuthError) -> [TrustedDevice] {
        let dto: TrustedDeviceListDTO
        do {
            dto = try await http.request(
                method: "GET",
                path: "/auth/trusted-devices",
                body: nil,
                headers: [:]
            )
        } catch {
            throw AuthError.from(transport: error)
        }
        return dto.trustedDevices.map { $0.toTrustedDevice() }
    }

    /// Register the current device as trusted. Returns a long-lived token to store
    /// (Keychain) and present on subsequent sign-ins to skip MFA.
    ///
    /// - Parameters:
    ///   - fingerprintHash: A stable, opaque identifier you generate for this device
    ///     (e.g., SHA-256 of `UIDevice.identifierForVendor` + app bundle ID).
    ///   - deviceName: Optional friendly name shown in the user's "trusted devices" list.
    public func registerTrustedDevice(
        fingerprintHash: String,
        deviceName: String? = nil
    ) async throws(AuthError) -> String {
        let dto: TrustedDeviceTokenDTO
        do {
            dto = try await http.request(
                method: "POST",
                path: "/auth/trusted-devices",
                body: RegisterTrustedDeviceBody(fingerprintHash: fingerprintHash, deviceName: deviceName),
                headers: [:]
            )
        } catch {
            throw AuthError.from(transport: error)
        }
        return dto.trustedDeviceToken
    }

    /// Revoke a trusted device. Future sign-ins from that device will require MFA again.
    public func revokeTrustedDevice(id: String) async throws(AuthError) {
        do {
            let _: SuccessResponseDTO = try await http.request(
                method: "DELETE",
                path: "/auth/trusted-devices/\(id)",
                body: nil,
                headers: [:]
            )
        } catch {
            throw AuthError.from(transport: error)
        }
    }
}
