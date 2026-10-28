import SwiftUI

/// Second page laid out like the Guardian app: AQI ring, round buttons, Auto-to-10 fan slider.
struct ClassicView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var outdoor = OutdoorAir.shared
    @ObservedObject private var geo = Geo.shared
    let purifier: Purifier
    @Binding var showSettings: Bool

    @State private var sheet: Sheet?
    @State private var fanDrag: Double?
    @State private var confirmFilterReset = false

    enum Sheet: String, Identifiable {
        case trends, filter, scenes, more
        var id: String { rawValue }
    }

    static let bg = Color(red: 0.16, green: 0.17, blue: 0.19)
    private let green = Color(red: 0.47, green: 0.78, blue: 0.40)

    private var active: Bool { purifier.isOn && purifier.info.online }
    private var aqi: Int? { purifier.pm25.map { USAQI.from(pm25: $0) } }

    var body: some View {
        ZStack {
            Self.bg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 26) {
                    HStack {
                        RoundButton(title: "Info", icon: "info.circle") { showSettings = true }
                        Spacer()
                        RoundButton(title: "Scenes", icon: "sparkles") { sheet = .scenes }
                        Spacer()
                        timerButton
                    }
                    ring
                    HStack(alignment: .top) {
                        RoundButton(title: "Trends", icon: "chart.xyaxis.line") { sheet = .trends }
                        Spacer()
                        RoundButton(title: "Filter", icon: "cylinder.split.1x2") { sheet = .filter }
                            .padding(.top, 40)
                        Spacer()
                        RoundButton(title: "More", icon: "slider.horizontal.3") { sheet = .more }
                    }
                    if let fan = fanControl {
                        fanSlider(fan)
                    } else if let mode = purifier.modeCode, let range = purifier.functions[mode]?.range {
                        VStack(spacing: 14) {
                            Text("Mode").font(.system(size: 26)).foregroundStyle(.white.opacity(0.6))
                            ChipRow(options: range, selected: purifier.string(mode), color: green,
                                    pending: store.pending.contains(mode), icons: true) { store.set(mode, .string($0)) }
                        }
                        .disabled(!active)
                        .opacity(active ? 1 : 0.5)
                    }
                    bottomRow
                }
                .padding(.horizontal, 22)
                .padding(.top, 8)
                .padding(.bottom, 50)
            }
            .refreshable { await store.refresh() }
        }
        .task { await outdoor.refresh() }
        .sheet(item: $sheet) { s in
            NavigationStack {
                ScrollView {
                    VStack(spacing: 16) {
                        switch s {
                        case .trends: PMChartView(samples: store.history, current: purifier.pm25)
                        case .filter: filterContent
                        case .scenes: ScenesCard()
                        case .more: moreContent
                        }
                    }
                    .padding(16)
                }
                .background(Theme.background(AQ.color(purifier.pm25)))
                .navigationTitle(s.rawValue.capitalized)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { sheet = nil } } }
            }
            .environmentObject(store)
            .presentationDetents([.medium, .large])
            .preferredColorScheme(.dark)
        }
    }

    // MARK: Ring

    private var ring: some View {
        let band = aqi.map(USAQI.band)
        let color = active ? (band?.color ?? green) : Theme.off
        return ZStack {
            Circle().fill(Self.bg)
                .shadow(color: .black.opacity(0.55), radius: 16, x: 8, y: 8)
                .shadow(color: .white.opacity(0.05), radius: 16, x: -8, y: -8)
            Circle().stroke(color, lineWidth: 6)
                .shadow(color: color.opacity(0.6), radius: 8)
                .padding(10)
            VStack(spacing: 4) {
                Button {
                    if geo.home == nil { geo.setHomeHere(radius: 200) } else { Task { await outdoor.refresh(force: true) } }
                } label: {
                    VStack(spacing: 0) {
                        Text("Outdoor").font(.system(size: 16))
                        Text(outdoor.aqi.map(String.init) ?? (geo.home == nil ? "Set" : "–"))
                            .font(.system(size: 22))
                            .foregroundStyle(outdoor.aqi.map { USAQI.band($0).color } ?? .white)
                    }
                }
                .buttonStyle(.plain)
                Text(aqi.map(String.init) ?? "–")
                    .font(.system(size: 96, weight: .light))
                    .contentTransition(.numericText(value: Double(aqi ?? 0)))
                    .animation(.snappy, value: aqi)
                    .padding(.vertical, -10)
                HStack(spacing: 14) {
                    Text("Indoor")
                    Rectangle().frame(width: 2, height: 14)
                    Text(band.map { $0 == .good ? "Excellent" : $0.label } ?? "No data")
                }
                .font(.system(size: 18))
                Text("AQI").font(.system(size: 26)).padding(.top, 10)
                Text(purifier.pm25.map { "PM2.5 \(Fmt.num($0.rounded())) µg/m³" } ?? "Air Quality Index")
                    .font(.system(size: 14)).foregroundStyle(.white.opacity(0.55))
            }
            .foregroundStyle(.white)
        }
        .frame(width: 300, height: 300)
        .opacity(purifier.info.online ? 1 : 0.6)
    }

    // MARK: Fan

    struct FanOption { let label: String; let commands: [(String, JSONValue)] }
    struct FanControl { let options: [FanOption]; let index: Int }

    /// Auto plus every speed the unit has. Auto comes from the speed list or, failing that, the mode list.
    private var fanControl: FanControl? {
        var opts: [FanOption] = []
        var current = 0
        if let fan = store.local.fanDP, !store.localFanValues.isEmpty,
           (store.localState.isConnected || purifier.speedCode == nil) {
            let values = store.localFanValues
            for v in values { opts.append(FanOption(label: v.display, commands: [("dp:\(fan)", v)])) }
            current = values.firstIndex(where: { $0 == store.localFan }) ?? 0
        } else if let code = purifier.speedCode, let spec = purifier.functions[code] {
        let speedNow = purifier.string(code)
        if spec.isEnum, let range = spec.range {
            for r in range { opts.append(FanOption(label: r.lowercased() == "auto" ? "AUTO" : Fmt.label(r), commands: [(code, .string(r))])) }
            current = range.firstIndex(of: speedNow ?? "") ?? 0
        } else if spec.isInt {
            let lo = Int(spec.min ?? 1), hi = Int(spec.max ?? 10), step = max(Int(spec.step ?? 1), 1)
            for v in stride(from: lo, through: hi, by: step) { opts.append(FanOption(label: "\(v)", commands: [(code, .int(v))])) }
            if let v = purifier.status[code]?.doubleValue { current = max(0, (Int(v) - lo) / step) }
        } else { return nil }
        } else { return nil }

        let hasAuto = opts.contains { $0.label == "AUTO" }
        if !hasAuto, let mode = purifier.modeCode, let range = purifier.functions[mode]?.range,
           let auto = range.first(where: { $0.lowercased() == "auto" || $0.lowercased() == "smart" }) {
            let manual = range.first { $0.lowercased() == "manual" }
            opts = opts.map { o in FanOption(label: o.label, commands: (manual.map { [(mode, JSONValue.string($0))] } ?? []) + o.commands) }
            opts.insert(FanOption(label: "AUTO", commands: [(mode, .string(auto))]), at: 0)
            current = purifier.string(mode) == auto ? 0 : current + 1
        }
        return FanControl(options: opts, index: min(current, max(opts.count - 1, 0)))
    }

    private func fanSlider(_ fan: FanControl) -> some View {
        let count = fan.options.count
        let shown = Int((fanDrag ?? Double(fan.index)).rounded())
        return VStack(spacing: 14) {
            Text("Fan").font(.system(size: 26)).foregroundStyle(.white.opacity(0.6))
            HStack(spacing: 0) {
                ForEach(Array(fan.options.enumerated()), id: \.offset) { i, o in
                    Text(o.label)
                        .font(.system(size: 14))
                        .foregroundStyle(i == shown ? green : .white.opacity(0.55))
                        .frame(maxWidth: .infinity)
                }
            }
            GeometryReader { geo in
                let w = geo.size.width
                let knob: CGFloat = 40
                let pos = count > 1 ? (fanDrag ?? Double(fan.index)) / Double(count - 1) : 0
                let x = knob / 2 + CGFloat(pos) * (w - knob)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.black.opacity(0.35)).frame(height: 16)
                    Capsule().fill(active ? green : Theme.off).frame(width: max(16, x), height: 16)
                    Circle().fill(Color.white).frame(width: knob, height: knob)
                        .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
                        .position(x: x, y: geo.size.height / 2)
                }
                .frame(height: geo.size.height)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            guard count > 1 else { return }
                            let p = min(max((g.location.x - knob / 2) / (w - knob), 0), 1)
                            let snapped = (Double(p) * Double(count - 1)).rounded()
                            if snapped != fanDrag?.rounded() { UISelectionFeedbackGenerator().selectionChanged() }
                            fanDrag = Double(p) * Double(count - 1)
                        }
                        .onEnded { _ in
                            let i = Int((fanDrag ?? Double(fan.index)).rounded())
                            withAnimation(.snappy) { fanDrag = Double(i) }
                            if i != fan.index { send(fan.options[i].commands) }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { fanDrag = nil }
                        }
                )
            }
            .frame(height: 44)
        }
        .disabled(!active || (purifier.speedCode == nil && !store.localState.isConnected))
        .opacity(active && (purifier.speedCode != nil || store.localState.isConnected) ? 1 : 0.5)
    }

    // MARK: Bottom buttons

    private struct Pill: Identifiable { let id: String; let title: String; let icon: String; let on: Bool; let action: () -> Void }

    private var pills: [Pill] {
        var out: [Pill] = []
        if let p = purifier.powerCode {
            out.append(Pill(id: p, title: "Power", icon: "power", on: purifier.isOn) { store.togglePower() })
        }
        if purifier.functions["sleep"]?.isBool == true {
            let on = purifier.bool("sleep") ?? false
            out.append(Pill(id: "sleep", title: "Sleep", icon: "moon", on: on) { store.set("sleep", .bool(!on)) })
        } else if let mode = purifier.modeCode, let range = purifier.functions[mode]?.range,
                  let sleep = range.first(where: { $0.lowercased() == "sleep" }) {
            let on = purifier.string(mode) == sleep
            let back = range.first { ["auto", "smart", "manual"].contains($0.lowercased()) } ?? range.first ?? sleep
            out.append(Pill(id: "mode-sleep", title: "Sleep", icon: "moon", on: on) { store.set(mode, .string(on ? back : sleep)) })
        }
        if let d = purifier.displayCode {
            let on = purifier.bool(d) ?? false
            out.append(Pill(id: d, title: "Display", icon: "lightbulb", on: on) { store.set(d, .bool(!on)) })
        } else if let d = store.local.displayDP {
            out.append(Pill(id: "dp:\(d)", title: "Display", icon: "lightbulb", on: store.localDisplayOn ?? false) { store.toggleLocalDisplay() })
        }
        for t in purifier.toggles where t.code != purifier.displayCode && t.code != "sleep" {
            let on = purifier.bool(t.code) ?? false
            let icon = t.code == "uv" ? "light.max" : t.icon
            out.append(Pill(id: t.code, title: t.title, icon: icon, on: on) { store.set(t.code, .bool(!on)) })
        }
        return out
    }

    private var bottomRow: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 22) {
            ForEach(pills) { p in
                RoundButton(title: p.title, icon: p.icon, size: 72, tint: p.on ? green : nil, action: p.action)
                    .disabled(!purifier.info.online || (p.title != "Power" && !purifier.isOn))
            }
        }
    }

    // MARK: Timer / filter / more

    @ViewBuilder
    private var timerButton: some View {
        if let code = purifier.timerCode, let range = purifier.functions[code]?.range {
            Menu {
                ForEach(range, id: \.self) { o in Button(Fmt.label(o)) { store.set(code, .string(o)) } }
            } label: {
                RoundFace(title: "Timer", icon: "clock", tint: (purifier.string(code).map { !["cancel", "off", "0"].contains($0) } ?? false) ? green : nil)
            }
        } else {
            RoundButton(title: "Timer", icon: "clock") { sheet = .more }
        }
    }

    private var filterContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(purifier.filterText ?? "No filter data").font(.system(size: 40, weight: .light))
            if let f = purifier.filterFraction {
                ProgressView(value: f).tint(f > 0.2 ? green : AQBand.unhealthy.color)
            }
            if let reset = purifier.filterResetCode {
                Button("Reset filter life") { confirmFilterReset = true }
                    .confirmationDialog("Reset filter life?", isPresented: $confirmFilterReset, titleVisibility: .visible) {
                        Button("Reset", role: .destructive) { store.set(reset, .bool(true)) }
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var moreContent: some View {
        VStack(spacing: 16) {
            if purifier.displayCode != nil || store.local.displayDP != nil {
                Toggle("Keep display off", isOn: $store.keepDisplayOff).card()
            }
            NavigationLink {
                LocalControlView().environmentObject(store)
            } label: {
                HStack {
                    Label("Wi-Fi control", systemImage: "wifi")
                    Spacer()
                    Text(store.localState.isConnected ? "Connected" : "Set up").foregroundStyle(.secondary)
                }
                .card()
            }
            .buttonStyle(.plain)
            ForEach(purifier.extraFunctions, id: \.code) { spec in
                GenericControl(spec: spec, value: purifier.status[spec.code], tint: green) { store.set(spec.code, $0) }
                    .card()
            }
            ForEach(purifier.readings, id: \.self) { r in
                HStack { Text(r.title); Spacer(); Text(purifier.readingText(r)).foregroundStyle(.secondary) }.card()
            }
        }
    }

    private func send(_ commands: [(String, JSONValue)]) {
        // A Wi-Fi fan speed (with or without a switch to Manual) goes through the sequenced path so the
        // firmware's reset-to-1 on entering Manual can't clobber it.
        if let fan = store.local.fanDP, let speed = commands.first(where: { $0.0 == "dp:\(fan)" })?.1 {
            store.setLocalFan(speed, manualMode: true)
            return
        }
        store.setMany(commands)
    }
}

struct RoundFace: View {
    let title: String
    let icon: String
    var size: CGFloat = 78
    var tint: Color? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: size * 0.36, weight: .light))
                .foregroundStyle(tint ?? .white)
                .frame(width: size, height: size)
                .background(
                    Circle().fill(ClassicView.bg)
                        .shadow(color: .black.opacity(0.55), radius: 8, x: 5, y: 5)
                        .shadow(color: .white.opacity(0.05), radius: 8, x: -5, y: -5)
                )
            Text(title).font(.system(size: 16)).foregroundStyle(.white.opacity(0.9))
        }
    }
}

struct RoundButton: View {
    let title: String
    let icon: String
    var size: CGFloat = 78
    var tint: Color? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) { RoundFace(title: title, icon: icon, size: size, tint: tint) }
            .buttonStyle(.plain)
            .sensoryFeedback(.impact(weight: .light), trigger: tint != nil)
    }
}
