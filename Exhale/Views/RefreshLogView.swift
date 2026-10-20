import SwiftUI

struct RefreshLogView: View {
    @State private var entries: [RefreshEntry] = []

    var body: some View {
        List {
            Section {
                ForEach(["Widget", "Background"], id: \.self) { src in
                    let runs = entries.filter { $0.source == src }
                    let lastNight = runs.filter { Date().timeIntervalSince($0.date) < 86400 }
                    HStack {
                        Text(src)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(runs.last.map { $0.date.formatted(.relative(presentation: .named)) } ?? "never")
                            Text("\(lastNight.count) runs in 24 h, \(lastNight.filter(\.ok).count) got a reading")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Summary")
            } footer: {
                Text("iOS decides when the widget and background refresh run. If these counts are low overnight, iOS isn't running them; if runs show errors, the refresh is failing.")
            }

            Section("Every run") {
                if entries.isEmpty {
                    Text("Nothing yet.").foregroundStyle(.secondary)
                }
                ForEach(entries.reversed()) { e in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: e.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(e.ok ? AQBand.good.color : AQBand.unhealthy.color)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(e.source).fontWeight(.semibold)
                                Spacer()
                                Text(e.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if let pm = e.pm { Text("PM2.5 \(Fmt.num(pm))").font(.caption) }
                            if let n = e.note { Text(n).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }

            Section {
                Button("Clear log", role: .destructive) {
                    RefreshLog.clear()
                    entries = []
                }
            }
        }
        .navigationTitle("Refresh log")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { entries = RefreshLog.load() }
        .refreshable { entries = RefreshLog.load() }
    }
}
