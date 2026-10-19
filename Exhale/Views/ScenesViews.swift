import SwiftUI
import CoreLocation

struct ScenesCard: View {
    @EnvironmentObject var store: AppStore
    @State private var editing: AirScene?
    @State private var running: String?
    @State private var done: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionTitle(text: "Scenes")
                Spacer()
                Button {
                    editing = AirScene(name: "", icon: "sparkles")
                } label: {
                    Image(systemName: "plus").font(.system(size: 15, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
            if store.scenes.isEmpty {
                Text("Run a set of settings with one tap, when you come or go, or when the air gets dirty or clean again.")
                    .font(.footnote).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    starter("Dirty air", "aqi.high", .pmAbove(35))
                    starter("Leaving", "figure.walk", .leave)
                    starter("Coming home", "house.fill", .arrive)
                }
            } else {
                ForEach(store.scenes) { s in
                    row(s)
                    if s.id != store.scenes.last?.id { Divider().opacity(0.3) }
                }
            }
        }
        .card()
        .sheet(item: $editing) { s in SceneEditor(scene: s).environmentObject(store) }
        .sensoryFeedback(.success, trigger: done)
    }

    private func starter(_ name: String, _ icon: String, _ trigger: SceneTrigger) -> some View {
        Button {
            editing = AirScene(name: name, icon: icon, trigger: trigger)
        } label: {
            Label(name, systemImage: icon)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Capsule().fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }

    private func row(_ s: AirScene) -> some View {
        HStack(spacing: 12) {
            Image(systemName: s.icon)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color.white.opacity(s.enabled ? 0.1 : 0.04)))
            VStack(alignment: .leading, spacing: 2) {
                Text(s.name.isEmpty ? "Scene" : s.name).font(.system(size: 15, weight: .semibold))
                HStack(spacing: 4) {
                    Image(systemName: s.trigger.icon).font(.system(size: 10))
                    Text(s.enabled ? s.trigger.label : "Paused")
                }
                .font(.caption).foregroundStyle(.secondary)
                Text(s.summary(store.purifier)).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
            Button {
                run(s)
            } label: {
                Group {
                    if running == s.id { ProgressView().controlSize(.small) }
                    else { Image(systemName: done == s.id ? "checkmark" : "play.fill").font(.system(size: 13, weight: .bold)) }
                }
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
        }
        .contentShape(Rectangle())
        .onTapGesture { editing = s }
        .opacity(s.enabled ? 1 : 0.55)
    }

    private func run(_ s: AirScene) {
        running = s.id
        Task {
            if (try? await store.runScene(s)) != nil {
                done = s.id
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if done == s.id { done = nil }
            }
            running = nil
        }
    }
}

struct SceneEditor: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var geo = Geo.shared
    @State var scene: AirScene

    @State private var kind = 0
    @State private var threshold: Double = 35
    @State private var values: [String: JSONValue] = [:]
    @State private var loaded = false

    private let icons = ["sparkles", "wind", "aqi.high", "aqi.low", "moon.zzz", "bed.double", "sun.max", "house.fill",
                         "figure.walk", "briefcase", "power", "leaf.fill", "fan", "flame", "pawprint.fill", "fork.knife"]

    private var purifier: Purifier? { store.purifier }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $scene.name)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(icons, id: \.self) { i in
                                Image(systemName: i)
                                    .frame(width: 36, height: 36)
                                    .background(Circle().fill(scene.icon == i ? Color.white.opacity(0.25) : Color.white.opacity(0.06)))
                                    .onTapGesture { scene.icon = i }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    Toggle("Enabled", isOn: $scene.enabled)
                }

                Section {
                    Picker("Trigger", selection: $kind) {
                        Text("Tap to run").tag(0)
                        Text("Arrive home").tag(1)
                        Text("Leave home").tag(2)
                        Text("PM2.5 rises above").tag(3)
                        Text("PM2.5 drops below").tag(4)
                    }
                    if kind >= 3 {
                        Stepper(value: $threshold, in: 2...300, step: threshold < 20 ? 1 : 5) {
                            HStack {
                                Text("\(Fmt.num(threshold)) µg/m³")
                                Text(AQBand.of(threshold).label).foregroundStyle(AQBand.of(threshold).color)
                            }
                        }
                    }
                } header: {
                    Text("When")
                } footer: {
                    Text(triggerFooter)
                }

                if kind == 1 || kind == 2 { homeSection }

                Section {
                    if let p = purifier {
                        ForEach(rows(p), id: \.code) { spec in actionRow(spec, p) }
                    } else {
                        Text("Pick a purifier first.").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Do")
                } footer: {
                    Text("Everything is sent as one command, and settings that are already right are skipped, so the purifier only reacts once.")
                }

                if store.scenes.contains(where: { $0.id == scene.id }) {
                    Section {
                        Button("Delete scene", role: .destructive) {
                            store.deleteScene(scene)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(scene.name.isEmpty ? "New scene" : scene.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(values.isEmpty)
                }
            }
            .onAppear(perform: load)
        }
        .preferredColorScheme(.dark)
    }

    private var triggerFooter: String {
        switch kind {
        case 1, 2: return "Uses your home location. iOS runs it in the background even if Exhale is closed, as long as location is set to Always."
        case 3, 4: return "Checked on every reading: live while Exhale is open, otherwise whenever the widget or background refresh runs (about every 15 to 30 min). Fires once per crossing. For instant reactions 24/7, make the same automation inside Smart Life, which runs on Tuya's servers."
        default: return "Run it from here."
        }
    }

    private var homeSection: some View {
        Section {
            if let h = geo.home {
                HStack {
                    Text("Home set")
                    Spacer()
                    Text(String(format: "%.4f, %.4f", h.lat, h.lon)).foregroundStyle(.secondary).font(.caption)
                }
                Stepper("Radius \(Int(h.radius)) m", value: Binding(get: { h.radius }, set: { geo.setRadius($0) }), in: 100...1000, step: 50)
            }
            Button(geo.locating ? "Finding you…" : (geo.home == nil ? "Set home to where I am now" : "Move home to where I am now")) {
                geo.setHomeHere(radius: geo.home?.radius ?? 200)
            }
            .disabled(geo.locating)
            if !geo.hasAlways {
                Label("Location needs to be set to Always for this to run in the background.", systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(AQBand.sensitive.color)
                Button("Allow location") { geo.requestAccess() }
            }
            if let e = geo.lastEvent {
                Text("Last: \(e)").font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Home")
        }
    }

    /// Controls worth putting in a scene: power first, then speed, mode, toggles, then the rest.
    private func rows(_ p: Purifier) -> [DPSpec] {
        var order: [String] = []
        for c in [p.powerCode, p.speedCode, p.modeCode].compactMap({ $0 }) { order.append(c) }
        order += p.toggles.map(\.code)
        order += p.extraFunctions.filter { $0.isBool || $0.isEnum }.map(\.code)
        if let t = p.timerCode { order.append(t) }
        var seen = Set<String>()
        return order.compactMap { c in
            guard !seen.contains(c), let s = p.functions[c], s.isBool || s.isEnum else { return nil }
            seen.insert(c)
            return s
        }
    }

    private func title(_ code: String, _ p: Purifier) -> String {
        if code == p.powerCode { return "Power" }
        if code == p.speedCode { return "Fan speed" }
        if code == p.modeCode { return "Mode" }
        if code == p.timerCode { return "Timer" }
        if let t = p.toggles.first(where: { $0.code == code }) { return t.title }
        return Fmt.label(code)
    }

    private func actionRow(_ spec: DPSpec, _ p: Purifier) -> some View {
        let binding = Binding<String>(
            get: { values[spec.code]?.stringValue ?? "__leave" },
            set: { new in
                if new == "__leave" { values[spec.code] = nil }
                else if spec.isBool { values[spec.code] = .bool(new == "true") }
                else { values[spec.code] = .string(new) }
            })
        return Picker(title(spec.code, p), selection: binding) {
            Text("Leave as is").tag("__leave")
            if spec.isBool {
                Text("On").tag("true")
                Text("Off").tag("false")
            } else {
                ForEach(spec.range ?? [], id: \.self) { o in Text(Fmt.label(o)).tag(o) }
            }
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        switch scene.trigger {
        case .manual: kind = 0
        case .arrive: kind = 1
        case .leave: kind = 2
        case .pmAbove(let v): kind = 3; threshold = v
        case .pmBelow(let v): kind = 4; threshold = v
        }
        for a in scene.actions { values[a.code] = a.value }
        // Sensible starting points for the starter scenes.
        if scene.actions.isEmpty, let p = purifier, let power = p.powerCode {
            switch scene.trigger {
            case .pmAbove:
                values[power] = .bool(true)
                if let sp = p.speedCode, let top = p.functions[sp]?.range?.last { values[sp] = .string(top) }
            case .pmBelow:
                if let mode = p.modeCode, let r = p.functions[mode]?.range, let auto = r.first(where: { $0.lowercased() == "auto" }) {
                    values[mode] = .string(auto)
                } else {
                    values[power] = .bool(false)
                }
            case .leave: values[power] = .bool(false)
            case .arrive: values[power] = .bool(true)
            case .manual: break
            }
        }
    }

    private func save() {
        switch kind {
        case 1: scene.trigger = .arrive
        case 2: scene.trigger = .leave
        case 3: scene.trigger = .pmAbove(threshold)
        case 4: scene.trigger = .pmBelow(threshold)
        default: scene.trigger = .manual
        }
        if scene.name.trimmingCharacters(in: .whitespaces).isEmpty { scene.name = scene.trigger.label }
        let order = purifier.map { rows($0).map(\.code) } ?? Array(values.keys)
        scene.actions = order.compactMap { c in values[c].map { SceneAction(code: c, value: $0) } }
        store.saveScene(scene)
        if scene.trigger.isLocation { geo.requestAccess() }
        dismiss()
    }
}
