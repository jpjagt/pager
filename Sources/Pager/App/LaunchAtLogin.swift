import ServiceManagement

enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// No-op failure outside a bundled .app (e.g. `swift run`); UI reads back
    /// isEnabled so the toggle reflects reality.
    static func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("LaunchAtLogin failed: \(error)")
        }
    }
}
