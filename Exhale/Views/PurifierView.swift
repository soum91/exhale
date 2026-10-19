import SwiftUI

struct PurifierView: View {
    @EnvironmentObject var store: AppStore
    let purifier: Purifier
    @State private var showSettings = false
    @State private var confirmFilterReset = false

    private var accent: Color { purifier.isOn && purifier.info.online ? AQ.color(purifier.pm25) : Theme.off }
    private var controlsEnabled: Bool { purifier.isOn && purifier.info.online }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background(accent).animation(.easeInOut(duration: 0.6), value: accent)
                ScrollView {
                    VStack(spacing: 16) {
                        hero
                        PMChartView(samples: store.history, current: purifier.pm25)
                        if let code = purifier.speedCode, let spec = purifier.functions[code] { speedCard(code, spec) }
                        if let code = purifier.modeCode, let spec = purifier.functions[code], spec.isEnum { modeCard(code, spec) }
                        if !purifier.toggles.isEmpty { togglesCard }
                        if let code = purifier.timerCode, let spec = purifier.functions[code] { timerCard(code, spec) }
                        if purifier.filterCode != nil || purifier.filterResetCode != nil { filterCard }
                        if !purifier.readings.isEmpty || purifier.airQualityCode != nil { readingsCard }
                        if !purifier.extraFunctions.isEmpty { extrasCard }
                        if let t = store.lastUpdate {
                            Text("Updated \(t.formatted(date: .omitted, time: .standard))")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 30)
                }
                .refreshable { await store.refresh() }
            }
            .navigationTitle(purifier.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView().environmentObject(store) }
        }
    }

    // MARK: Hero

    private var hero: some View {
        let pm = purifier.pm25
        let band = pm.map(AQBand.of)
        let fraction = min((pm ?? 0) / 75, 1)
        return VStack(spacing: 18) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.07), lineWidth: 14)
                Circle()
                    .trim(from: 0, to: max(0.02, fraction))
                    .stroke(AngularGradient(colors: [AQBand.good.color, band?.color ?? Theme.off], center: .center,
                                            startAngle: .degrees(0), endAngle: .degrees(360 * max(0.02, fraction))),
                            style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.spring(duration: 0.8), value: fraction)
                Circle().fill(accent.opacity(0.10)).padding(24).blur(radius: 18)
                VStack(spacing: 2) {
                    Text("PM2.5").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
                    Text(AQ.value(pm))
                        .font(.system(size: 72, weight: .semibold, design: .rounded))
                        .contentTransition(.numericText(value: pm ?? 0))
                        .animation(.snappy, value: pm)
                    Text("µg/m³").font(.footnote).foregroundStyle(.white.opacity(0.5))
                    Text(band?.label ?? "No reading")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(band?.color ?? Theme.off)
                        .padding(.top, 4)
                }
            }
            .frame(width: 240, height: 240)
            .padding(.top, 8)

            HStack(spacing: 14) {
                if purifier.powerCode != nil {
                    Button { store.togglePower() } label: {
                        HStack(spacing: 8) {
                            if store.pending.contains(purifier.powerCode ?? "") {
                                ProgressView().tint(purifier.isOn ? .black : .white)
                            } else {
                                Image(systemName: "power").font(.system(size: 17, weight: .bold))
                            }
                            Text(purifier.isOn ? "On" : "Off").font(.system(size: 17, weight: .semibold))
                        }
                        .frame(width: 120, height: 50)
                        .background(Capsule().fill(purifier.isOn ? Color.white : Color.white.opacity(0.1)))
                        .foregroundStyle(purifier.isOn ? Color.black : Color.white)
                    }
                    .buttonStyle(.plain)
                    .sensoryFeedback(.impact, trigger: purifier.isOn)
                }
                FanBadge(spinning: purifier.isOn && purifier.info.online, speedText: speedText)
            }

            if !purifier.info.online {
                Label("Purifier is offline", systemImage: "wifi.slash")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var speedText: String? {
        guard let code = purifier.speedCode, let v = purifier.string(code) else { return nil }
        return Fmt.label(v)
    }

    // MARK: Speed

    @ViewBuilder
    private func speedCard(_ code: String, _ spec: DPSpec) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: "Fan speed")
            if spec.isEnum, let options = spec.range {
                ChipRow(options: options, selected: purifier.string(code), color: accent, pending: store.pending.contains(code)) {
                    store.set(code, .string($0))
                }
            } else if spec.isInt {
                IntSlider(spec: spec, value: purifier.status[code]?.doubleValue ?? spec.min ?? 0, tint: accent) {
                    store.set(code, .int($0))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .disabled(!controlsEnabled)
        .opacity(controlsEnabled ? 1 : 0.5)
    }

    // MARK: Mode

    private func modeCard(_ code: String, _ spec: DPSpec) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: "Mode")
            ChipRow(options: spec.range ?? [], selected: purifier.string(code), color: accent, pending: store.pending.contains(code), icons: true) {
                store.set(code, .string($0))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .disabled(!controlsEnabled)
        .opacity(controlsEnabled ? 1 : 0.5)
    }

    // MARK: Toggles

    private var togglesCard: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(purifier.toggles, id: \.self) { t in
                let on = purifier.bool(t.code) ?? false
                Button { store.set(t.code, .bool(!on)) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: t.icon)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(on ? Color.black : Color.white.opacity(0.8))
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(on ? accent : Color.white.opacity(0.08)))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(t.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                            Text(on ? "On" : "Off").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(on ? accent.opacity(0.5) : Theme.stroke))
                }
                .buttonStyle(.plain)
                .sensoryFeedback(.selection, trigger: on)
            }
        }
        .disabled(!purifier.info.online)
    }

    // MARK: Timer

    private func timerCard(_ code: String, _ spec: DPSpec) -> some View {
        HStack {
            Image(systemName: "timer").font(.title3).foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Timer").font(.headline)
                if let left = purifier.timerLeftCode.flatMap({ purifier.number($0) }), left > 0 {
                    Text("\(Int(left)) min left").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(Fmt.label(purifier.string(code) ?? "off")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if spec.isEnum, let options = spec.range {
                Menu {
                    ForEach(options, id: \.self) { o in
                        Button(Fmt.label(o)) { store.set(code, .string(o)) }
                    }
                } label: {
                    Text("Set").fontWeight(.semibold)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(Capsule().fill(Color.white.opacity(0.1)))
                }
            } else if spec.isInt {
                Stepper("", value: Binding(get: { purifier.status[code]?.doubleValue ?? 0 },
                                           set: { store.set(code, .int(Int($0))) }),
                        in: (spec.min ?? 0)...(spec.max ?? 1440), step: max(spec.step ?? 1, 1))
                    .labelsHidden()
            }
        }
        .card()
        .disabled(!controlsEnabled)
        .opacity(controlsEnabled ? 1 : 0.5)
    }

    // MARK: Filter

    private var filterCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionTitle(text: "Filter")
                Spacer()
                if let text = purifier.filterText {
                    Text(text).font(.system(size: 15, weight: .semibold, design: .rounded))
                }
            }
            if let f = purifier.filterFraction {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08))
                        Capsule().fill(f > 0.2 ? AQBand.good.color : (f > 0.05 ? AQBand.sensitive.color : AQBand.unhealthy.color))
                            .frame(width: max(8, geo.size.width * f))
                    }
                }
                .frame(height: 8)
                if f <= 0.1 {
                    Text("Time to replace the filter.").font(.caption).foregroundStyle(AQBand.sensitive.color)
                }
            }
            if let reset = purifier.filterResetCode {
                Button("Reset filter life") { confirmFilterReset = true }
                    .font(.subheadline.weight(.semibold))
                    .confirmationDialog("Reset filter life?", isPresented: $confirmFilterReset, titleVisibility: .visible) {
                        Button("Reset", role: .destructive) { store.set(reset, .bool(true)) }
                    } message: {
                        Text("Only do this after putting in a new filter.")
                    }
            }
        }
        .card()
    }

    // MARK: Readings

    private var readingsCard: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            if let aq = purifier.airQualityCode, let v = purifier.string(aq) {
                tile(icon: "aqi.medium", title: "Air quality", value: Fmt.label(v))
            }
            ForEach(purifier.readings, id: \.self) { r in
                tile(icon: r.icon, title: r.title, value: purifier.readingText(r))
            }
        }
    }

    private func tile(icon: String, title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon).foregroundStyle(accent)
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    // MARK: Anything else the device exposes

    private var extrasCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(text: "More")
            ForEach(purifier.extraFunctions, id: \.code) { spec in
                GenericControl(spec: spec, value: purifier.status[spec.code], tint: accent) {
                    store.set(spec.code, $0)
                }
                if spec.code != purifier.extraFunctions.last?.code { Divider().opacity(0.3) }
            }
        }
        .card()
        .disabled(!purifier.info.online)
    }
}

// MARK: - Pieces

struct FanBadge: View {
    let spinning: Bool
    let speedText: String?

    var body: some View {
        HStack(spacing: 8) {
            TimelineView(.animation(paused: !spinning)) { ctx in
                let angle = spinning ? ctx.date.timeIntervalSinceReferenceDate * 360 : 0
                Image(systemName: "fan")
                    .font(.system(size: 18, weight: .semibold))
                    .rotationEffect(.degrees(angle.truncatingRemainder(dividingBy: 360)))
            }
            Text(speedText.map { "Fan \($0)" } ?? (spinning ? "Running" : "Idle"))
                .font(.system(size: 15, weight: .semibold))
        }
        .foregroundStyle(spinning ? Color.white : Color.white.opacity(0.5))
        .frame(height: 50)
        .padding(.horizontal, 18)
        .background(Capsule().fill(Color.white.opacity(0.08)))
    }
}

struct ChipRow: View {
    let options: [String]
    let selected: String?
    let color: Color
    var pending: Bool = false
    var icons: Bool = false
    let action: (String) -> Void

    private func icon(_ o: String) -> String? {
        switch o.lowercased() {
        case "auto", "smart": return "sparkles"
        case "sleep", "night": return "moon.fill"
        case "manual": return "hand.raised.fill"
        case "turbo", "strong", "max": return "bolt.fill"
        case "eco": return "leaf.fill"
        case "quiet", "silent": return "speaker.slash.fill"
        default: return nil
        }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(options, id: \.self) { o in
                    let on = o == selected
                    Button { action(o) } label: {
                        HStack(spacing: 6) {
                            if icons, let i = icon(o) { Image(systemName: i).font(.system(size: 13, weight: .semibold)) }
                            Text(Fmt.label(o)).font(.system(size: 15, weight: .semibold))
                        }
                        .padding(.horizontal, 16)
                        .frame(minWidth: 48, minHeight: 42)
                        .background(Capsule().fill(on ? color : Color.white.opacity(0.08)))
                        .foregroundStyle(on ? Color.black : Color.white)
                        .opacity(on && pending ? 0.6 : 1)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .sensoryFeedback(.selection, trigger: selected)
    }
}

struct IntSlider: View {
    let spec: DPSpec
    let value: Double
    let tint: Color
    let commit: (Int) -> Void
    @State private var local: Double?

    var body: some View {
        let lo = spec.min ?? 0, hi = max(spec.max ?? 100, (spec.min ?? 0) + 1)
        VStack(alignment: .leading, spacing: 6) {
            Text("\(Fmt.num((local ?? value) / spec.divisor))\(spec.unit ?? "")")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
            Slider(value: Binding(get: { local ?? value }, set: { local = $0 }),
                   in: lo...hi, step: max(spec.step ?? 1, 1), onEditingChanged: { editing in
                if !editing, let l = local {
                    commit(Int(l.rounded()))
                    local = nil
                }
            })
            .tint(tint)
        }
    }
}

struct GenericControl: View {
    let spec: DPSpec
    let value: JSONValue?
    let tint: Color
    let set: (JSONValue) -> Void

    var body: some View {
        HStack {
            Text(spec.name.flatMap { $0.isEmpty ? nil : $0 } ?? Fmt.label(spec.code))
                .font(.subheadline)
            Spacer()
            if spec.isBool {
                Toggle("", isOn: Binding(get: { value?.boolValue ?? false }, set: { set(.bool($0)) }))
                    .labelsHidden().tint(tint)
            } else if spec.isEnum, let options = spec.range {
                Menu {
                    ForEach(options, id: \.self) { o in Button(Fmt.label(o)) { set(.string(o)) } }
                } label: {
                    HStack(spacing: 4) {
                        Text(Fmt.label(value?.stringValue ?? "–"))
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                    }
                    .foregroundStyle(.white.opacity(0.8))
                }
            } else if spec.isInt {
                let cur = value?.doubleValue ?? spec.min ?? 0
                Stepper(Fmt.num(cur / spec.divisor) + (spec.unit ?? ""),
                        value: Binding(get: { cur }, set: { set(.int(Int($0))) }),
                        in: (spec.min ?? 0)...max(spec.max ?? 100, (spec.min ?? 0) + 1),
                        step: max(spec.step ?? 1, 1))
                    .fixedSize()
            }
        }
    }
}
