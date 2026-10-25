import Foundation
@MainActor enum ExhaleQuickActions {
    static func run(_ action: PurifierQuickAction) async throws {
        guard let p = await PurifierSync.refresh(source: "Control Center") else { throw TuyaError(message: "Open Exhale and select your purifier.") }
        let store = AppStore.shared
        if (action == .fanUp || action == .fanDown), store.local.enabled, store.local.fanDP != nil {
            store.startLocal()
            await store.localTask?.value
            await store.queryLocal()
            guard let dp = store.local.fanDP, let current = store.localFan,
                  let index = store.localFanValues.firstIndex(of: current), !store.localFanValues.isEmpty else {
                throw TuyaError(message: "Can't read the purifier's local fan speed. Open Exhale near the purifier.")
            }
            let values = store.localFanValues
            let next = max(0, min(values.count - 1, index + (action == .fanUp ? 1 : -1)))
            if let mode = p.modeCode, let manual = p.functions[mode]?.range?.first(where: { $0.lowercased() == "manual" }), p.string(mode) != manual {
                try await PurifierSync.send(mode, .string(manual))
            }
            try await store.sendLocal([dp: values[next]])
            return
        }
        if action == .display, store.local.enabled, let dp = store.local.displayDP {
            store.startLocal(); await store.localTask?.value; await store.queryLocal()
            guard let on = store.localDisplayOn else { throw TuyaError(message: "The purifier's local display state is unavailable.") }
            if !on { store.keepDisplayOff = false }
            try await store.sendLocal([dp: .bool(!on != store.local.displayInverted)])
            return
        }
        switch action {
        case .fanUp, .fanDown:
            guard let code = p.speedCode, let spec = p.functions[code] else { throw TuyaError(message: "No fan control exposed by this purifier.") }
            let step = action == .fanUp ? 1 : -1
            if let values = spec.range, !values.isEmpty, let value = p.string(code), let i = values.firstIndex(of: value) {
                try await PurifierSync.send(code, .string(values[max(0, min(values.count - 1, i + step))]))
            } else if spec.isInt, let current = p.status[code]?.doubleValue, let low = spec.min, let high = spec.max {
                let next = max(low, min(high, current + Double(step) * (spec.step ?? 1)))
                try await PurifierSync.send(code, .int(Int(next)))
            } else { throw TuyaError(message: "Can't determine this purifier's fan speed range.") }
        case .auto, .sleep:
            guard let code = p.modeCode, let value = p.functions[code]?.range?.first(where: { $0.lowercased() == (action == .auto ? "auto" : "sleep") }) else {
                if action == .sleep, p.functions["sleep"]?.isBool == true { try await PurifierSync.send("sleep", .bool(true)); return }
                throw TuyaError(message: "This purifier does not expose that mode.")
            }
            try await PurifierSync.send(code, .string(value))
        case .display:
            guard let code = p.displayCode, let on = p.bool(code) else { throw TuyaError(message: "No display switch exposed by this purifier.") }
            if !on { store.keepDisplayOff = false }
            try await PurifierSync.send(code, .bool(!on))
        }
    }
}
