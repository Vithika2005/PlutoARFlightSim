import Foundation
import simd
import Combine
import SwiftUI

// MARK: - Types

/// Disarmed → Armed → Taking Off → Flying (hover = flying with ~0 speed) → Landing → Landed
enum FlightState: String {
    case disarmed = "DISARMED"
    case armed = "ARMED"
    case takingOff = "TAKING OFF"
    case flying = "FLYING"
    case landing = "LANDING"
    case landed = "LANDED"

    var isGrounded: Bool { self == .disarmed || self == .armed || self == .landed }
    var isAirborne: Bool { !isGrounded }

    var uiColor: UIColor {
        switch self {
        case .disarmed: return .systemRed
        case .armed: return .systemOrange
        case .takingOff, .landing: return .systemYellow
        case .flying: return .systemGreen
        case .landed: return .systemBlue
        }
    }
    var color: Color { Color(uiColor) }
}

/// Stick values in -1...1.  Left stick = throttle + yaw, right stick = pitch + roll (Mode 2).
struct StickInput: Equatable {
    var throttle: Float = 0   // +up
    var yaw: Float = 0        // +turn right (clockwise seen from above)
    var pitch: Float = 0      // +forward
    var roll: Float = 0       // +right
}

/// A vertical pillar standing on the floor.
struct Obstacle: Equatable {
    var position: SIMD3<Float>
    var radius: Float
    var height: Float
}

struct HUDState: Equatable {
    var altitude: Float = 0
    var speed: Float = 0
    var heading: Float = 0
    var homeDistance: Float = 0
    var hovering = false
    var input = StickInput()
}

struct Banner: Equatable {
    let id = UUID()
    let text: String
    let isError: Bool
    let expires: Date
}

// MARK: - Flight model

/// Simplified quadcopter model. Everything is in the AR anchor's local space:
/// +X right, +Y up, -Z = the direction the drone's nose points at yaw 0.
/// The drone starts at (0,0,0) = the spot where you placed it.
final class FlightModel: ObservableObject {
    // Low-rate published values (UI)
    @Published private(set) var state: FlightState = .disarmed
    @Published private(set) var hud = HUDState()
    @Published private(set) var banner: Banner?
    @Published private(set) var collisions = 0
    @Published private(set) var violations = 0

    // High-rate simulation values (read by the renderer every frame)
    private(set) var position = SIMD3<Float>(0, 0, 0)
    private(set) var velocity = SIMD3<Float>(0, 0, 0)
    private(set) var yaw: Float = 0
    private(set) var tiltForward: Float = 0
    private(set) var tiltRight: Float = 0
    private(set) var time: Float = 0

    // Inputs / configuration
    var input = StickInput()
    var obstacles: [Obstacle] = []
    var driftStrength: Float = 0          // simulated wind
    var paused = false                    // set when AR tracking is lost
    var suppressGroundWarnings = false    // tutorial stage 1 lets you wiggle sticks freely

    private var hudClock: Float = 0
    private var lastCollision: Float = -10
    private var lastShown: [String: Double] = [:]

    var forward: SIMD3<Float> { SIMD3<Float>(-sin(yaw), 0, -cos(yaw)) }
    var right: SIMD3<Float> { SIMD3<Float>(cos(yaw), 0, -sin(yaw)) }
    var altitude: Float { position.y }
    var homeDistance: Float { (position.x * position.x + position.z * position.z).squareRoot() }

    // MARK: Commands (virtual buttons)

    func toggleArm() {
        switch state {
        case .disarmed:
            setState(.armed)
            notify("Armed – motors idling. Tap TAKE OFF.")
        case .armed, .landed:
            setState(.disarmed)
            notify("Disarmed.")
        default:
            notify("Land first – you cannot disarm in flight.", error: true)
        }
    }

    func takeOff() {
        switch state {
        case .armed, .landed: setState(.takingOff)
        case .disarmed: notify("Arm the drone first (tap ARM).", error: true)
        default: notify("Already airborne.", error: true)
        }
    }

    func land() {
        switch state {
        case .flying, .takingOff: setState(.landing)
        case .landing: break
        default: notify("The drone is already on the ground.", error: true)
        }
    }

    func reset() {
        position = SIMD3<Float>(0, 0, 0)
        velocity = SIMD3<Float>(0, 0, 0)
        yaw = 0; tiltForward = 0; tiltRight = 0
        input = StickInput()
        collisions = 0; violations = 0
        banner = nil
        lastShown = [:]
        state = .disarmed
    }

    // MARK: Messages

    func notify(_ text: String, error: Bool = false) { _ = show(text, error: error) }

    func registerViolation(_ text: String) {
        violations += 1
        _ = show(text, error: true)
    }

    func expireBanner() {
        if let b = banner, b.expires < Date() { banner = nil }
    }

    @discardableResult
    private func show(_ text: String, error: Bool) -> Bool {
        let now = Date().timeIntervalSinceReferenceDate
        if let t = lastShown[text], now - t < 2.0 { return false }
        lastShown[text] = now
        banner = Banner(text: text, isError: error, expires: Date().addingTimeInterval(2.5))
        return true
    }

    private func setState(_ s: FlightState) {
        if state != s { state = s }
    }

    // MARK: Simulation step (called every rendered frame)

    func step(_ rawDt: Float) {
        guard !paused else { return }
        let dt = min(max(rawDt, 0), 0.05)
        time += dt

        let maxH = Config.maxHorizontalSpeed
        let planar = forward * (input.pitch * maxH) + right * (input.roll * maxH)
        var cmd = SIMD3<Float>(0, 0, 0)
        var yawRate: Float = 0

        switch state {
        case .disarmed, .armed, .landed:
            groundedInputCheck()                       // invalid operation → warning, no movement
        case .takingOff:
            cmd.y = Config.takeoffSpeed
            if position.y >= Config.takeoffAltitude { setState(.flying) }
        case .flying:
            cmd = SIMD3<Float>(planar.x, input.throttle * Config.maxClimbSpeed, planar.z)
            yawRate = -input.yaw * Config.maxYawRate
        case .landing:
            cmd = SIMD3<Float>(planar.x * 0.5, -Config.landingSpeed, planar.z * 0.5)
            yawRate = -input.yaw * Config.maxYawRate * 0.5
        }

        if state.isAirborne {
            cmd += wind()
            // "Stabilisation": velocity eases toward the command; sticks centred = hold position/altitude.
            let k = min(1, dt * 5)
            velocity += (cmd - velocity) * k
            yaw += yawRate * dt
            let impact = velocity.y
            position += velocity * dt
            applyLimits()
            applyCollisions()

            if position.y <= 0 {                       // ground detection
                position.y = 0
                if state == .landing || (state == .flying && input.throttle < -0.05) {
                    touchdown(impact: impact)
                } else {
                    velocity.y = max(0, velocity.y)
                }
            }
        } else {
            velocity = SIMD3<Float>(0, 0, 0)
        }

        // Visual tilt follows the real body-frame velocity
        let bf = max(-1.3, min(1.3, simd_dot(velocity, forward) / maxH))
        let br = max(-1.3, min(1.3, simd_dot(velocity, right) / maxH))
        let kt = min(1, dt * 8)
        tiltForward += (bf * Config.maxTilt - tiltForward) * kt
        tiltRight += (br * Config.maxTilt - tiltRight) * kt

        hudClock += dt
        if hudClock >= 0.05 {
            hudClock = 0
            publishHUD()
        }
    }

    // MARK: Helpers

    private func touchdown(impact: Float) {
        if impact < -Config.hardLandingSpeed {
            registerViolation("Hard landing – descend more slowly.")
        }
        velocity = SIMD3<Float>(0, 0, 0)
        setState(.landed)
    }

    private func groundedInputCheck() {
        guard !suppressGroundWarnings else { return }
        let big = abs(input.throttle) > 0.5 || abs(input.pitch) > 0.5 || abs(input.roll) > 0.5
        guard big else { return }
        if state == .disarmed {
            notify("Drone is DISARMED – tap ARM before flying.", error: true)
        } else {
            notify("Tap TAKE OFF to lift off first.", error: true)
        }
    }

    private func applyLimits() {
        if position.y > Config.maxAltitude {
            position.y = Config.maxAltitude
            velocity.y = min(0, velocity.y)
            notify("Altitude limit reached.", error: true)
        }
        let d = homeDistance
        if d > Config.boundaryRadius {
            let s = Config.boundaryRadius / d
            position.x *= s
            position.z *= s
            velocity.x = 0
            velocity.z = 0
            notify("Flight boundary – fly back toward the pad.", error: true)
        }
    }

    private func applyCollisions() {
        for o in obstacles {
            let dx = position.x - o.position.x
            let dz = position.z - o.position.z
            let d = max((dx * dx + dz * dz).squareRoot(), 0.0001)
            let minD = o.radius + Config.droneRadius
            if d < minD && position.y < o.height + Config.droneRadius * 0.5 {
                position.x = o.position.x + dx / d * minD
                position.z = o.position.z + dz / d * minD
                velocity.x = dx / d * 0.25
                velocity.z = dz / d * 0.25
                if time - lastCollision > 1.0 {
                    lastCollision = time
                    collisions += 1
                    notify("Collision! Steer around the obstacle.", error: true)
                }
            }
        }
    }

    private func wind() -> SIMD3<Float> {
        guard driftStrength > 0 else { return SIMD3<Float>(0, 0, 0) }
        let t = time
        let x = sin(t * 0.7) + 0.5 * sin(t * 1.9 + 1.0)
        let z = cos(t * 0.5 + 2.0) + 0.5 * sin(t * 1.3)
        return SIMD3<Float>(x, 0, z) * driftStrength
    }

    private func publishHUD() {
        var h = -yaw * 180 / .pi
        h = h.truncatingRemainder(dividingBy: 360)
        if h < 0 { h += 360 }
        let speed = simd_length(velocity)
        let new = HUDState(altitude: position.y,
                           speed: speed,
                           heading: h,
                           homeDistance: homeDistance,
                           hovering: state == .flying && speed < 0.1,
                           input: input)
        if new != hud { hud = new }
        expireBanner()
    }
}
