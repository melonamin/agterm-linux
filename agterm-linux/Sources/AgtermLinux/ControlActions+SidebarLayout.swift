import Foundation
import agtermCore

@MainActor
extension AppController {
    func setFlaggedViewLayout(_ mode: ControlFlaggedLayoutMode) -> ControlResponse {
        let settingsStore = linuxSettingsStore()
        var settings = settingsStore.load()
        let current = settings.effectiveFlaggedViewLayout
        let layout: FlaggedViewLayout = switch mode {
        case .flat: .flat
        case .plain: .plain
        case .tree: .tree
        case .toggle: current == .tree ? .flat : .tree
        }
        if current != layout {
            settings.flaggedViewLayout = layout == .flat ? nil : layout.rawValue
            do {
                try settingsStore.save(settings)
            } catch {
                return err("could not save flagged view layout")
            }
            library.setFlaggedLayout(layout)
            for controller in gWindows.values {
                controller.syncSidebar(force: true)
            }
        }
        return ControlResponse(ok: true, result: ControlResult(text: layout.rawValue))
    }
}
