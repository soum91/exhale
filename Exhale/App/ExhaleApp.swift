import SwiftUI
import BackgroundTasks
import WidgetKit

@main
struct ExhaleApp: App {
    @StateObject private var store = AppStore.shared
    @Environment(\.scenePhase) private var phase

    init() {
        // Must exist at launch so iOS can deliver arrive/leave events when it relaunches the app in the background.
        _ = Geo.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
        }
        .onChange(of: phase, initial: true) { _, newPhase in
            switch newPhase {
            case .active:
                store.startPolling()
            case .background:
                store.stopPolling()
                Self.scheduleRefresh()
            default:
                break
            }
        }
        .backgroundTask(.appRefresh(AppStore.refreshID)) {
            await Self.scheduleRefreshAsync()
            await PurifierSync.refresh()
            await MainActor.run { WidgetCenter.shared.reloadAllTimelines() }
        }
    }

    static func scheduleRefresh() {
        let req = BGAppRefreshTaskRequest(identifier: AppStore.refreshID)
        req.earliestBeginDate = Date().addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(req)
    }

    static func scheduleRefreshAsync() async {
        scheduleRefresh()
    }
}

struct RootView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        Group {
            if store.token == nil {
                LoginView()
            } else if let p = store.purifier {
                PurifierView(purifier: p)
            } else {
                DevicePickerView()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: store.token == nil)
        .animation(.easeInOut(duration: 0.25), value: store.purifier?.id)
        .alert("Something went wrong", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.error ?? "")
        }
    }
}
