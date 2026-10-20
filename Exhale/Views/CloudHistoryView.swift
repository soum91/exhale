import SwiftUI

struct CloudHistoryView: View {
    @EnvironmentObject var store: AppStore
    @State private var cfg = CloudHistoryConfig.stored
    @State private var busy = false

    var body: some View {
        Form {
            Section {
                TextField("Access ID / Client ID", text: $cfg.accessID)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Access Secret / Client Secret", text: $cfg.secret)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Picker("Data center", selection: $cfg.host) {
                    ForEach(CloudHistoryConfig.regions, id: \.host) { r in Text(r.name).tag(r.host) }
                }
                Button {
                    save()
                    busy = true
                    Task {
                        var c = CloudHistoryConfig.stored
                        c.lastFetched = nil          // re-pull the full 7 days
                        CloudHistoryConfig.stored = c
                        let r = await CloudBackfill.run()
                        RefreshLog.add("Cloud history", ok: !(r ?? "").contains("failed"), note: r)
                        store.history = History.load()
                        cfg = CloudHistoryConfig.stored
                        busy = false
                    }
                } label: {
                    HStack {
                        Text("Save and fetch last 7 days")
                        if busy { Spacer(); ProgressView() }
                    }
                }
                .disabled(busy || cfg.accessID.isEmpty || cfg.secret.isEmpty)
                if let r = cfg.lastResult {
                    Text(r).font(.footnote)
                        .foregroundStyle(r.contains("failed") ? AQBand.unhealthy.color : AQBand.good.color)
                }
            } header: {
                Text("Tuya developer keys")
            } footer: {
                Text("Once set, Exhale fills the graph with the purifier's real readings from Tuya's cloud every time you open it, so gaps while the app was closed become actual data instead of a bridged line.")
            }

            Section("One-time setup (about 10 minutes)") {
                step(1, "Go to iot.tuya.com and sign up for a free developer account.")
                step(2, "Cloud › Development › Create Cloud Project. Any name, industry Smart Home, development method Smart Home, and pick the data center your Smart Life account is in (Western America for Canada).")
                step(3, "In the project, open Devices › Link App Account › Add App Account, and scan the QR with Smart Life (Me › scan icon). Your purifier should appear in the device list.")
                step(4, "Open Service API and make sure IoT Core and Device Log Query (or Device Status Notification) are authorized.")
                step(5, "Copy the Access ID and Access Secret from the project Overview into the fields above.")
                Text("The free IoT Core plan has to be extended every 6 months from the same site (one click). The cloud keeps about 7 days of logs.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            if cfg.isSet {
                Section {
                    Button("Remove keys", role: .destructive) {
                        cfg = CloudHistoryConfig()
                        CloudHistoryConfig.stored = cfg
                    }
                }
            }
        }
        .navigationTitle("Cloud history")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear(perform: save)
    }

    private func save() {
        var c = CloudHistoryConfig.stored
        c.accessID = cfg.accessID.trimmingCharacters(in: .whitespacesAndNewlines)
        c.secret = cfg.secret.trimmingCharacters(in: .whitespacesAndNewlines)
        c.host = cfg.host
        CloudHistoryConfig.stored = c
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.footnote.weight(.bold)).frame(width: 20, height: 20)
                .background(Circle().fill(Color.white.opacity(0.12)))
            Text(text).font(.footnote)
        }
    }
}
