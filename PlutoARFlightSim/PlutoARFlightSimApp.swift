import SwiftUI

/// Holds the three long-lived objects. It has no @Published properties on purpose,
/// so the root view never re-renders; each HUD piece observes only what it needs.
final class AppModel: ObservableObject {
    let flight: FlightModel
    let engine: TrainingEngine
    let ar = ARStatus()

    init() {
        let f = FlightModel()
        flight = f
        engine = TrainingEngine(flight: f)
    }
}

@main
struct PlutoARFlightSimApp: App {
    @StateObject private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(app)
        }
    }
}
