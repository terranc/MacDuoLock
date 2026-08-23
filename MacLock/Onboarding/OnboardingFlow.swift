import Foundation

@MainActor
final class OnboardingFlow {
    let passwords: PasswordStore
    let secrets: GateSecretsStore
    let gate: SessionGate

    init(passwords: PasswordStore, secrets: GateSecretsStore, gate: SessionGate) {
        self.passwords = passwords
        self.secrets = secrets
        self.gate = gate
    }

    func complete(password: String, confirm: String) async throws {
        guard password.count >= PasswordStore.minimumLength else {
            throw PasswordStoreError.tooShort(length: password.count)
        }
        guard password == confirm else { throw PasswordStoreError.mismatch }
        try await passwords.setPassword(password)
        secrets.clearCleanDisarm()
        gate.handle(.armVerified)
    }

    func armAfterPasswordConfirmed() {
        secrets.clearCleanDisarm()
        gate.handle(.armVerified)
    }
}
