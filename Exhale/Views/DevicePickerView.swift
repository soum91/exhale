import SwiftUI

struct DevicePickerView: View {
    @EnvironmentObject var store: AppStore
    @State private var selecting: String?

    var body: some View {
        NavigationStack {
            List {
                let purifiers = store.devices.filter(\.isPurifier)
                let others = store.devices.filter { !$0.isPurifier }
                if store.devices.isEmpty {
                    Section {
                        if store.loadingDevices {
                            HStack { ProgressView(); Text("Loading your Smart Life devices…").foregroundStyle(.secondary) }
                        } else {
                            Text("No devices found. Make sure the purifier is in the Smart Life account you signed in with, then pull to refresh.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if !purifiers.isEmpty {
                    Section("Air purifiers") { ForEach(purifiers) { row($0) } }
                }
                if !others.isEmpty {
                    Section {
                        ForEach(others) { row($0) }
                    } header: {
                        Text("Other devices")
                    } footer: {
                        Text("If your purifier shows up here instead, pick it anyway. Exhale reads whatever data points it reports.")
                    }
                }
                Section {
                    Button("Sign out", role: .destructive) { store.signOut() }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background(AQBand.good.color))
            .navigationTitle("Choose purifier")
            .refreshable { await store.loadDevices() }
            .task { if store.devices.isEmpty { await store.loadDevices() } }
        }
    }

    private func row(_ d: DeviceInfo) -> some View {
        Button {
            selecting = d.id
            Task {
                await store.select(d)
                selecting = nil
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: d.isPurifier ? "aqi.medium" : "square.grid.2x2")
                    .font(.title3)
                    .foregroundStyle(d.isPurifier ? AQBand.good.color : .secondary)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.name).foregroundStyle(.white)
                    Text([d.productName, d.online ? nil : "Offline"].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if selecting == d.id { ProgressView() } else { Image(systemName: "chevron.right").foregroundStyle(.tertiary) }
            }
        }
        .disabled(selecting != nil)
        .listRowBackground(Theme.card)
    }
}
