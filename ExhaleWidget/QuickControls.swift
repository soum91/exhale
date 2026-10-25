import SwiftUI
import WidgetKit
import AppIntents
@available(iOS 18.0, *) struct PurifierPowerProvider: ControlValueProvider {
    var previewValue: Bool { false }
    func currentValue() async throws -> Bool {
        guard let p = Cache.purifier else { throw TuyaError(message: "Open Exhale and select a purifier.") }
        return p.isOn
    }
}
@available(iOS 18.0, *) struct PurifierPowerControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.soum91.exhale.power", provider: PurifierPowerProvider()) { on in
            ControlWidgetToggle("Air purifier", isOn: on, action: PurifierPowerSwitchIntent()) {
                Label($0 ? "On" : "Off", systemImage: "fan.fill")
            }
        }.displayName("Purifier power").description("Switch your purifier on or off.")
    }
}
@available(iOS 18.0, *) struct PurifierActionControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: "com.soum91.exhale.action", intent: PurifierControlConfig.self) { config in
            ControlWidgetButton(action: PurifierActionIntent(config.action)) { Label(config.action.rawValue.capitalized, systemImage: config.action.symbol) }
        }.displayName("Purifier action").description("Fan up/down, Auto, Sleep or display. Only supported device settings can run.")
    }
}
