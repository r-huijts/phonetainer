import LocalAuthentication

enum DeviceAuthentication {
    /// "Face ID", "Touch ID" or "Optic ID", or "passcode" on devices without biometrics.
    static var methodName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        case .none: return "passcode"
        @unknown default: return "passcode"
        }
    }

    static var symbolName: String {
        switch methodName {
        case "Face ID": return "faceid"
        case "Touch ID": return "touchid"
        case "Optic ID": return "opticid"
        default: return "lock"
        }
    }

    /// Biometrics with the device passcode as fallback.
    static func authenticate(reason: String) async throws {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw error ?? LAError(.passcodeNotSet)
        }
        _ = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
    }

    /// True for errors that mean "the user backed out", which need no message.
    static func isCancellation(_ error: Error) -> Bool {
        guard let error = error as? LAError else { return false }
        return error.code == .userCancel || error.code == .appCancel || error.code == .systemCancel
    }
}
