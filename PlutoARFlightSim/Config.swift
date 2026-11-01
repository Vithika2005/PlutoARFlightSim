import Foundation

/// Every tunable number lives here. Units: metres, seconds, radians.
enum Config {
    // ---- Drone model ---------------------------------------------------
    /// File name (without extension) of the organiser-provided model: PlutoDrone.usdz
    static let modelName = "PlutoDrone"
    /// On-screen size of the drone (longest horizontal side). The real Pluto is tiny,
    /// so we show it bigger to keep it readable in a room.
    static let droneSize: Float = 0.30
    /// If the model's nose does not point away from you at start, rotate it here (try 90, 180, -90).
    static let modelYawOffsetDegrees: Float = 0
    /// Spin nodes whose name contains "prop", "rotor" or "blade" (only if the model has them).
    static let spinModelPropellers = false

    // ---- Flight envelope -----------------------------------------------
    static let maxAltitude: Float = 2.0
    static let boundaryRadius: Float = 2.0
    static let maxClimbSpeed: Float = 0.6
    static let maxHorizontalSpeed: Float = 0.7
    static let maxYawRate: Float = 1.6          // rad/s
    static let takeoffAltitude: Float = 0.5     // auto-takeoff climbs to here
    static let takeoffSpeed: Float = 0.45
    static let landingSpeed: Float = 0.3
    static let hardLandingSpeed: Float = 0.45   // touching down faster than this = warning
    static let maxTilt: Float = 0.30            // visual tilt, radians
    static let droneRadius: Float = 0.12        // collision radius
}
