import AppKit
import Foundation

enum ProcessRole: Equatable {
    case agent
    case user

    static func current(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ProcessRole {
        if arguments.contains("--role=agent") { return .agent }
        if environment["MACLOCK_ROLE"] == "agent" { return .agent }
        return .user
    }
}

enum QuitIntent {
    case none
    case handoffUserInstance
    case agentDuplicateTimeout
    case unregisterAndQuit
}

func otherMacLockApps() -> [NSRunningApplication] {
    NSRunningApplication.runningApplications(withBundleIdentifier: "app.maclock")
        .filter { $0.processIdentifier != getpid() }
}
