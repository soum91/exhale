import SwiftUI
import Combine

/// Connect over Wi-Fi and work out which raw data point is the fan speed and which is the display.
struct LocalControlView: View {
    @EnvironmentObject var store: AppStore
    @State private var hostText = ""
    @State private var editing: String?
    @State private var tick = Date()

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    Circle()
                        .fill(store.localState.isConnected ? AQBand.good.color : Theme.off)
                        .frame(width: 10, height: 10)
                    Text(store.localState.text).font(.subheadline)
                }
                Toggle("Use Wi-Fi control", isOn: Binding(get: { store.local.enabled }, set: { v in
                    store.local.enabled = v
                    store.saveLocal()
                    if v { store.startLocal() } else { store.stopLocal() }
                }))
                Button {
                    store.findOnWiFi()
                } label: {
                    Label("Find purifier on Wi-Fi", systemImage: "wifi")
                }
                .disabled(isBusy)
                HStack {
                    TextField("Or type its IP, e.g. 192.168.1.40", text: $hostText)
                        .keyboardType(.decimalPad)
                        .autocorrectionDisabled()
                    Button("Connect") {
                        store.local.host = hostText.trimmingCharacters(in: .whitespaces)
                        store.local.version = nil
                        store.saveLocal()
                        store.reconnectLocal()
                    }
                    .disabled(hostText.isEmpty || isBusy)
                }
                if store.purifier?.info.localKey == nil {
                    Text("Tuya didn't send a local key for this purifier, so Wi-Fi control won't work. Pull to refresh the device list and try again.")
                        .font(.footnote).foregroundStyle(AQBand.sensitive.color)
                }
            } header: {
                Text("Connection")
            } footer: {
                Text("Talks straight to the purifier on your network, so it sees the data points Tuya's cloud hides and commands land instantly. Only works on the same Wi-Fi. iOS will ask to allow Local Network the first time.")
            }

            Section {
                mappingRow("Fan speed", dp: store.local.fanDP, values: store.local.fanValues.map(\.display))
                mappingRow("Display", dp: store.local.displayDP, values: nil)
                if store.local.displayDP != nil {
                    Toggle("Display value is inverted", isOn: Binding(get: { store.local.displayInverted }, set: {
                        store.local.displayInverted = $0
                        store.saveLocal()
                    }))
                    HStack {
                        Text("Screen right now")
                        Spacer()
                        Text(store.localDisplayOn.map { $0 ? "On" : "Off" } ?? "–").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Mapped controls")
            } footer: {
                Text("Open the Guardian app next to this screen. Slide the fan through every speed from 1 to 10, then flip Display on and off. The data point that lights up is the one: tap it and pick what it is. If \"Screen right now\" says Off while the screen is lit, turn on Inverted.")
            }

            Section {
                if store.localDPS.isEmpty {
                    Text(store.localState.isConnected ? "Waiting for data…" : "Connect to see the raw data points.")
                        .foregroundStyle(.secondary)
                }
                ForEach(sortedIDs, id: \.self) { id in
                    dpRow(id)
                }
            } header: {
                Text("Raw data points")
            }
        }
        .navigationTitle("Wi-Fi control")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            hostText = store.local.host ?? ""
            store.startLocal()
        }
        .onReceive(timer) { t in
            tick = t
            if store.localState.isConnected, Int(t.timeIntervalSince1970) % 3 == 0 {
                Task { await store.queryLocal() }
            }
        }
        .sheet(item: Binding(get: { editing.map { DPRef(id: $0) } }, set: { editing = $0?.id })) { ref in
            DPEditor(id: ref.id).environmentObject(store)
                .presentationDetents([.medium])
        }
    }

    private var isBusy: Bool {
        switch store.localState {
        case .searching, .connecting: return true
        default: return false
        }
    }

    private var sortedIDs: [String] {
        store.localDPS.keys.sorted { (Int($0) ?? 9999, $0) < (Int($1) ?? 9999, $1) }
    }

    private func mappingRow(_ title: String, dp: String?, values: [String]?) -> some View {
        HStack {
            Text(title)
            Spacer()
            if let dp {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("DP \(dp)").foregroundStyle(AQBand.good.color)
                    if let values, !values.isEmpty {
                        Text("seen: " + values.joined(separator: ", ")).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("Not set").foregroundStyle(.secondary)
            }
        }
    }

    private func dpRow(_ id: String) -> some View {
        let changed = store.localChanged[id].map { tick.timeIntervalSince($0) < 6 } ?? false
        let name = store.local.codeMap[id]
        return Button { editing = id } label: {
            HStack {
                Text(id)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .frame(width: 44, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label(id, name))
                        .font(.subheadline)
                    if let seen = store.local.observed[id], seen.count > 1 {
                        Text("seen: " + seen.suffix(10).map(\.display).joined(separator: ", "))
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Text(store.localDPS[id]?.display ?? "–")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(changed ? Color.black : Color.white)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6).fill(changed ? AQBand.moderate.color : Color.clear))
                    .animation(.easeOut(duration: 0.3), value: changed)
            }
        }
        .foregroundStyle(.white)
    }

    private func label(_ id: String, _ cloud: String?) -> String {
        if id == store.local.fanDP { return "Fan speed" }
        if id == store.local.displayDP { return "Display" }
        if let cloud { return Fmt.label(cloud) + " (cloud: \(cloud))" }
        return "Hidden from cloud"
    }
}

private struct DPRef: Identifiable { let id: String }

struct DPEditor: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let id: String
    @State private var text = ""
    @State private var number: Double = 0

    var body: some View {
        NavigationStack {
            Form {
                Section("Current value") {
                    Text(store.localDPS[id]?.display ?? "–").font(.system(.title2, design: .monospaced))
                }
                Section("This is…") {
                    Button("Fan speed") {
                        store.local.fanDP = id
                        if store.local.displayDP == id { store.local.displayDP = nil }
                        store.saveLocal()
                        dismiss()
                    }
                    Button("Display") {
                        store.local.displayDP = id
                        if store.local.fanDP == id { store.local.fanDP = nil }
                        store.saveLocal()
                        dismiss()
                    }
                    if store.local.fanDP == id || store.local.displayDP == id {
                        Button("Nothing (clear)", role: .destructive) {
                            if store.local.fanDP == id { store.local.fanDP = nil }
                            if store.local.displayDP == id { store.local.displayDP = nil }
                            store.saveLocal()
                            dismiss()
                        }
                    }
                }
                Section {
                    switch store.localDPS[id] ?? .null {
                    case .bool(let b):
                        Button(b ? "Send OFF" : "Send ON") { send(.bool(!b)) }
                    case .int:
                        Stepper("\(Int(number))", value: $number)
                        Button("Send \(Int(number))") { send(.int(Int(number))) }
                    default:
                        TextField("Value", text: $text).autocorrectionDisabled().textInputAutocapitalization(.never)
                        Button("Send \"\(text)\"") { send(.string(text)) }.disabled(text.isEmpty)
                    }
                } header: {
                    Text("Test it")
                } footer: {
                    Text("Sends a value straight to the purifier. Handy for checking what a data point does.")
                }
            }
            .navigationTitle("DP \(id)")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                text = store.localDPS[id]?.stringValue ?? ""
                number = store.localDPS[id]?.doubleValue ?? 0
            }
        }
        .preferredColorScheme(.dark)
    }

    private func send(_ v: JSONValue) {
        Task {
            do { try await store.sendLocal([id: v]) } catch { store.error = error.localizedDescription }
        }
    }
}
