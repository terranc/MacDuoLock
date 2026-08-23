import Foundation
import ServiceManagement

final class LoginItemService {
    func registerMainApp() throws {
        try SMAppService.mainApp.register()
    }

    func unregisterMainApp() throws {
        try SMAppService.mainApp.unregister()
    }

    func registerAgent() throws {
        try SMAppService.agent(plistName: "app.maclock.agent.plist").register()
    }

    func unregisterAgent() throws {
        try SMAppService.agent(plistName: "app.maclock.agent.plist").unregister()
    }

    var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    func openSettings() throws {
        SMAppService.openSystemSettingsLoginItems()
    }
}
