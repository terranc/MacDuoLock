import Foundation

@MainActor
final class ArmDisarmController {
    let passwords: PasswordStore
    let secrets: GateSecretsStore
    let gate: SessionGate

    init(passwords: PasswordStore, secrets: GateSecretsStore, gate: SessionGate) {
        self.passwords = passwords
        self.secrets = secrets
        self.gate = gate
    }

    func disarm(password: String) async -> PasswordVerifyResult {
        let result = await passwords.verify(password)
        if result == .accepted {
            secrets.writeCleanDisarm()
            gate.handle(.disarmVerified)
        }
        return result
    }

    func arm(password: String) async -> PasswordVerifyResult {
        let result = await passwords.verify(password)
        if result == .accepted {
            secrets.clearCleanDisarm()
            gate.handle(.armVerified)
        }
        return result
    }
}
