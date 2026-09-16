import SwiftUI

@main
struct TroughWatchApp: App {
    @StateObject private var store = TroughStore()
    @StateObject private var locator = LocationManager()
    @StateObject private var receiver = ReceiverClient()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(locator)
                .environmentObject(receiver)
        }
    }
}

/// Shows the one-time home setup until a home location exists, then the main app.
struct RootView: View {
    @EnvironmentObject private var store: TroughStore
    @EnvironmentObject private var locator: LocationManager
    @EnvironmentObject private var receiver: ReceiverClient

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if store.home == nil {
                HomeSetupView()
            } else {
                MainTabView()
            }
        }
        .animation(.default, value: store.home == nil)
        .task {
            locator.requestAuthorization()
            locator.startUpdating()

            // Every packet the receiver decodes gets filed against a trough.
            receiver.onSnapshot = { [store] snapshot, stationTroughID in
                store.apply(snapshot, preferring: stationTroughID)
            }
            receiver.start()
        }
        .onChange(of: scenePhase) { _, phase in
            // Only a real trip to the background stops the poll. `.inactive`
            // also fires for a permission alert or the app switcher, and the
            // feed should still be running when the farmer comes straight back.
            switch phase {
            case .active: receiver.start()
            case .background: receiver.stop()
            default: break
            }
        }
    }
}
