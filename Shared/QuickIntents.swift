import AppIntents
import WidgetKit

enum PurifierQuickAction: String, AppEnum {
    case fanUp, fanDown, auto, sleep, display
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Purifier action"
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [.fanUp: "Fan up", .fanDown: "Fan down", .auto: "Auto mode", .sleep: "Sleep mode", .display: "Toggle display"]
    var symbol: String { self == .display ? "lightbulb" : self == .sleep ? "moon.fill" : "fan.fill" }
}
struct PurifierActionIntent: LiveActivityIntent {
    #if WIDGET_EXTENSION
    // The widget extension cannot be launched to run intents on this iOS, so
    // Shortcuts must only see (and run) the copy inside the app.
    static let isDiscoverable = false
    #endif
    static var title: LocalizedStringResource = "Control Air Purifier"
    @Parameter(title: "Action") var action: PurifierQuickAction
    init() { action = .auto }
    init(_ action: PurifierQuickAction) { self.action = action }
    @MainActor func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        try await ExhaleQuickActions.run(action)
        #endif
        WidgetCenter.shared.reloadAllTimelines()
        if #available(iOS 18.0, *) { ControlCenter.shared.reloadAllControls() }
        return .result()
    }
}
@available(iOS 18.0, *) struct PurifierPowerSwitchIntent: SetValueIntent {
    #if WIDGET_EXTENSION
    // The widget extension cannot be launched to run intents on this iOS, so
    // Shortcuts must only see (and run) the copy inside the app.
    static let isDiscoverable = false
    #endif
    static var title: LocalizedStringResource = "Purifier power"
    @Parameter(title: "On") var value: Bool
    func perform() async throws -> some IntentResult {
        try await PurifierSync.setPower(value)
        WidgetCenter.shared.reloadAllTimelines()
        ControlCenter.shared.reloadAllControls()
        return .result()
    }
}
@available(iOS 18.0, *) struct PurifierControlConfig: ControlConfigurationIntent {
    static var title: LocalizedStringResource = "Purifier action"
    @Parameter(title: "Action", default: .auto) var action: PurifierQuickAction
}
