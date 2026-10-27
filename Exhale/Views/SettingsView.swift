import SwiftUI
import UIKit
import WidgetKit

struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            List {
                if let p = store.purifier {
                    Section("Device") {
                        row("Name", p.name)
                        row("Product", p.info.productName.isEmpty ? "–" : p.info.productName)
                        row("Category", p.info.category)
                        row("Status", p.info.online ? "Online" : "Offline")
                        Button("Switch device") {
                            dismiss()
                            store.forgetDevice()
                        }
                    }
                }

                Section {
                    NavigationLink {
                        LocalControlView().environmentObject(store)
                    } label: {
                        HStack {
                            Label("Wi-Fi control", systemImage: "wifi")
                            Spacer()
                            Text(store.localState.isConnected ? "Connected" : (store.local.host == nil ? "Set up" : "Off"))
                                .foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("Unlocks fan speed and display, which Tuya's cloud doesn't expose for this purifier.")
                }

                Section {
                    NavigationLink {
                        HomeBridgeView().environmentObject(store)
                    } label: {
                        HStack {
                            Label("Apple Home bridge", systemImage: "homekit")
                            Spacer()
                            Text(HomeBridgeLink.stored.isSet ? "Paired" : "Set up").foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("Puts the purifier, PM2.5 and filter life in the Home app through Afterglow's ESP32 bridge.")
                }

                Section {
                    NavigationLink {
                        CloudHistoryView().environmentObject(store)
                    } label: {
                        HStack {
                            Label("Cloud history", systemImage: "icloud.and.arrow.down")
                            Spacer()
                            Text(CloudHistoryConfig.stored.isSet ? "On" : "Set up").foregroundStyle(.secondary)
                        }
                    }
                    NavigationLink {
                        RefreshLogView()
                    } label: {
                        Label("Refresh log", systemImage: "list.bullet.rectangle")
                    }
                    row("Readings logged", "\(store.history.count)")
                    if let first = store.history.first {
                        row("Since", first.t.formatted(date: .abbreviated, time: .shortened))
                    }
                    Button("Clear history", role: .destructive) { confirmClear = true }
                } header: {
                    Text("History")
                } footer: {
                    Text("Tuya doesn't keep PM2.5 history for us, so Exhale logs it on the phone: every 20 s while the app is open, plus each time the widget or a background refresh runs (roughly every 15–30 min). Keep a widget on your home screen to fill gaps.")
                }

                Section {
                    row("Widget data sharing", AppGroup.isShared ? "Working" : "Not available")
                    row("App Group", AppGroup.activeGroup ?? "none")
                    row("Signed groups", AppGroup.signedGroups().isEmpty ? "none" : AppGroup.signedGroups().joined(separator: "\n"))
                    row("Shared folders", "\(AppGroup.containers.count)")
                    row("Bundle ID", Bundle.main.bundleIdentifier ?? "?")
                    row("Version", AppGroup.version)
                    Button("Refresh widgets") { WidgetCenter.shared.reloadAllTimelines() }
                } header: {
                    Text("Widget")
                } footer: {
                    if !AppGroup.isShared {
                        Text(AppGroup.signedGroups().isEmpty
                             ? "The sideloader signed Exhale without any App Group, so the widget has nowhere shared to read from. Screenshot this section and send it over."
                             : "Exhale is signed with an App Group but iOS won't open it. Screenshot this section and send it over.")
                    }
                }

                Section {
                    Button(copied ? "Copied" : "Copy device data") { copyRaw() }
                } header: {
                    Text("Troubleshooting")
                } footer: {
                    Text("Copies the raw data points and spec. Paste it to Claude if a control is missing or labelled wrong.")
                }

                Section("Account") {
                    if let t = store.token {
                        row("User code", t.userCode)
                        row("Region", URL(string: t.endpoint)?.host ?? t.endpoint)
                    }
                    Button("Sign out", role: .destructive) {
                        dismiss()
                        store.signOut()
                    }
                }

                Section {
                    Text("Exhale uses the same Smart Life cloud as Home Assistant's Tuya integration. Not affiliated with Tuya.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Clear PM2.5 history?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear", role: .destructive) {
                    History.clear()
                    store.history = []
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }

    private func copyRaw() {
        guard let p = store.purifier else { return }
        var lines = ["Device: \(p.name) | category \(p.info.category) | product \(p.info.productName)", "", "Status:"]
        for (k, v) in p.status.sorted(by: { $0.key < $1.key }) { lines.append("  \(k) = \(v.display)") }
        lines.append("")
        lines.append("Functions (writable):")
        for s in p.functions.values.sorted(by: { $0.code < $1.code }) { lines.append("  " + describe(s)) }
        lines.append("")
        lines.append("Status spec:")
        for s in p.statusSpec.values.sorted(by: { $0.code < $1.code }) { lines.append("  " + describe(s)) }
        UIPasteboard.general.string = lines.joined(separator: "\n")
        copied = true
    }

    private func describe(_ s: DPSpec) -> String {
        var parts = ["\(s.code) [\(s.type)]"]
        if let r = s.range { parts.append("range " + r.joined(separator: ",")) }
        if let lo = s.min, let hi = s.max { parts.append("\(Fmt.num(lo))...\(Fmt.num(hi))") }
        if let sc = s.scale, sc != 0 { parts.append("scale \(sc)") }
        if let u = s.unit, !u.isEmpty { parts.append("unit \(u)") }
        return parts.joined(separator: " ")
    }
}
