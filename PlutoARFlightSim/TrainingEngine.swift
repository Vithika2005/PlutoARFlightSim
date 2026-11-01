import Foundation
import simd
import Combine

// MARK: - Data model

/// Which on-screen control the tutorial wants the user to touch (gets a pulsing highlight).
enum Control { case arm, takeoff, land, leftStick, rightStick, bothSticks }

/// What the user must actually DO to finish a step (validated against the live flight model).
enum Goal {
    case practiceSticks
    case arm
    case takeoff(altitude: Float)
    case hover(altitude: Float, radius: Float, seconds: Float)
    case directions(distance: Float)
    case navigate(points: [SIMD3<Float>])
    case land(padRadius: Float)
    case disarm
}

struct Step {
    let title: String
    let instruction: String
    let tip: String          // shown if the user is stuck for >10 s
    let goal: Goal
}

struct Activity: Identifiable {
    let id: String
    let title: String
    let summary: String
    let steps: [Step]
    var obstacles: [Obstacle] = []
    var drift: Float = 0.04                       // simulated wind strength
    var altitudeBand: ClosedRange<Float>? = nil   // mission limit while hovering / moving
    var parSeconds: Float = 120
    var isTutorial = false
}

/// Things drawn in the AR scene (checkpoint orbs, hover zone, landing pad).
struct Marker: Identifiable, Equatable {
    enum Kind { case orb, zone, pad }
    enum Status { case pending, active, done }
    let id: Int
    var kind: Kind
    var position: SIMD3<Float>
    var radius: Float
    var status: Status
    var label: String
}

struct CheckItem: Identifiable, Equatable {
    let id: Int
    let label: String
    var value: Float      // 0...1
}

struct Report: Equatable {
    let title: String
    let score: Int?
    let time: Float
    let collisions: Int
    let violations: Int
    let stability: Int?
    let isTutorial: Bool
    let newBest: Bool
}

struct SavedProgress: Codable {
    var best: [String: Int] = [:]
    var completed: [String] = []
    private static let key = "plutosim.progress.v1"

    static func load() -> SavedProgress {
        guard let d = UserDefaults.standard.data(forKey: key),
              let p = try? JSONDecoder().decode(SavedProgress.self, from: d) else { return SavedProgress() }
        return p
    }
    func save() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: SavedProgress.key) }
    }
}

// MARK: - Engine

final class TrainingEngine: ObservableObject {
    @Published private(set) var activity: Activity?
    @Published private(set) var stepIndex = 0
    @Published private(set) var progress: Float = 0
    @Published private(set) var hint = ""
    @Published private(set) var tip: String?
    @Published private(set) var flash: String?
    @Published private(set) var highlight: Control?
    @Published private(set) var markers: [Marker] = []
    @Published private(set) var obstacles: [Obstacle] = []
    @Published private(set) var checklist: [CheckItem] = []
    @Published private(set) var zoneOK = true
    @Published private(set) var report: Report?
    @Published private(set) var saved = SavedProgress.load()

    private let flight: FlightModel
    private var stepTime: Float = 0
    private var elapsed: Float = 0
    private var hold: Float = 0
    private var navIndex = 0
    private var dirDist: [Float] = [0, 0, 0, 0]
    private var seen = Set<Int>()
    private var hoverIn: Float = 0
    private var hoverTotal: Float = 0
    private var flashUntil: Float?
    private var bandLatched = false

    init(flight: FlightModel) { self.flight = flight }

    // MARK: Control

    func start(_ a: Activity) {
        flight.reset()
        flight.obstacles = a.obstacles
        flight.driftStrength = a.drift
        activity = a
        obstacles = a.obstacles
        report = nil
        stepIndex = 0
        elapsed = 0; hoverIn = 0; hoverTotal = 0
        flash = nil; flashUntil = nil; bandLatched = false
        enterStep()
    }

    func startFreeFlight() {
        activity = nil
        report = nil
        markers = []; checklist = []; obstacles = []
        hint = ""; tip = nil; highlight = nil; flash = nil; progress = 0; zoneOK = true
        flight.reset()
        flight.obstacles = []
        flight.driftStrength = 0
        flight.suppressGroundWarnings = false
    }

    func restart() {
        if let a = activity { start(a) } else { startFreeFlight() }
    }

    func skipStep() {
        guard let a = activity, report == nil else { return }
        complete(a.steps[stepIndex])
    }

    func resetProgress() {
        saved = SavedProgress()
        saved.save()
    }

    // MARK: Step setup

    private func enterStep() {
        guard let a = activity else { return }
        let step = a.steps[stepIndex]
        stepTime = 0; hold = 0; navIndex = 0
        dirDist = [0, 0, 0, 0]
        seen = []
        progress = 0
        tip = nil
        zoneOK = true
        checklist = []
        markers = []
        flight.suppressGroundWarnings = false

        switch step.goal {
        case .practiceSticks:
            flight.suppressGroundWarnings = true
            let names = ["Throttle ↑", "Throttle ↓", "Yaw ←", "Yaw →", "Pitch ↑", "Pitch ↓", "Roll ←", "Roll →"]
            checklist = names.enumerated().map { CheckItem(id: $0.offset, label: $0.element, value: 0) }
        case .directions:
            let names = ["Forward", "Back", "Left", "Right"]
            checklist = names.enumerated().map { CheckItem(id: $0.offset, label: $0.element, value: 0) }
        case .takeoff(let alt):
            markers = [Marker(id: 0, kind: .zone, position: SIMD3<Float>(0, alt, 0), radius: 0.2,
                              status: .active, label: String(format: "%.1f m", alt))]
        case .hover(let alt, let r, _):
            markers = [Marker(id: 0, kind: .zone, position: SIMD3<Float>(0, alt, 0), radius: r,
                              status: .active, label: String(format: "HOLD %.1f m", alt))]
        case .navigate(let pts):
            markers = pts.enumerated().map {
                Marker(id: $0.offset, kind: .orb, position: $0.element, radius: 0.18,
                       status: $0.offset == 0 ? .active : .pending, label: "\($0.offset + 1)")
            }
        case .land(let r):
            markers = [Marker(id: 0, kind: .pad, position: SIMD3<Float>(0, 0, 0), radius: r,
                              status: .active, label: "LAND")]
        case .arm, .disarm:
            break
        }
        setGuide(step.instruction, nil)
    }

    // MARK: Per-frame validation

    func update(dt: Float) {
        guard let a = activity, report == nil, !flight.paused else { return }
        elapsed += dt
        stepTime += dt
        if let until = flashUntil, elapsed > until { flash = nil; flashUntil = nil }

        let step = a.steps[stepIndex]
        let s = flight.state
        let pos = flight.position
        var done = false

        applyAltitudeBand(a, step)

        switch step.goal {

        case .practiceSticks:
            let i = flight.input
            let flags: [Bool] = [i.throttle > 0.6, i.throttle < -0.6, i.yaw < -0.6, i.yaw > 0.6,
                                 i.pitch > 0.6, i.pitch < -0.6, i.roll < -0.6, i.roll > 0.6]
            for (idx, f) in flags.enumerated() where f { seen.insert(idx) }
            setChecklist((0..<8).map { seen.contains($0) ? 1 : 0 })
            setProgress(Float(seen.count) / 8)
            let missing = checklist.filter { $0.value < 1 }.map { $0.label }
            if missing.isEmpty {
                setGuide("All controls tested!", nil)
            } else {
                setGuide("Push each stick fully in every direction. Left to try: " + missing.joined(separator: ", "), .bothSticks)
            }
            done = seen.count == 8

        case .arm:
            if s == .disarmed {
                setGuide("Tap ARM (green button) to arm the motors.", .arm)
            } else {
                done = true
            }
            setProgress(done ? 1 : 0)

        case .takeoff(let alt):
            let ok = s == .flying && abs(pos.y - alt) <= 0.1
            hold = ok ? hold + dt : 0
            zoneOK = ok || s != .flying
            setProgress(min(hold, 1))
            if !groundGuide(s) {
                if pos.y < alt - 0.1 {
                    setGuide(String(format: "Push the LEFT stick UP to climb into the green zone (%.1f m).", alt), .leftStick)
                } else if pos.y > alt + 0.1 {
                    setGuide("Too high – pull the LEFT stick DOWN a little.", .leftStick)
                } else {
                    setGuide("Hold this altitude…", nil)
                }
            }
            done = hold >= 1.0

        case .hover(let alt, let r, let secs):
            let horiz = (pos.x * pos.x + pos.z * pos.z).squareRoot()
            let inside = s == .flying && horiz <= r && abs(pos.y - alt) <= 0.15
            if s == .flying {
                hoverTotal += dt
                if inside { hoverIn += dt }
            }
            hold = inside ? hold + dt : 0
            zoneOK = inside || s != .flying
            setProgress(min(hold / secs, 1))
            if !groundGuide(s) {
                if inside {
                    setGuide(String(format: "Hold steady… %.0f s", max(0, (secs - hold).rounded(.up))), nil)
                } else {
                    driftGuide(pos: pos, alt: alt, r: r, horiz: horiz)
                }
            }
            done = hold >= secs

        case .directions(let d):
            if s == .flying {
                let v = flight.velocity
                let fv = simd_dot(v, flight.forward)
                let rv = simd_dot(v, flight.right)
                let i = flight.input
                if i.pitch > 0.2 { dirDist[0] += max(0, fv) * dt }
                if i.pitch < -0.2 { dirDist[1] += max(0, -fv) * dt }
                if i.roll < -0.2 { dirDist[2] += max(0, -rv) * dt }
                if i.roll > 0.2 { dirDist[3] += max(0, rv) * dt }
            }
            let vals = dirDist.map { min($0 / d, 1) }
            setChecklist(vals)
            setProgress(vals.reduce(0, +) / 4)
            if !groundGuide(s) {
                let names = ["Forward", "Back", "Left", "Right"]
                let missing = zip(names, vals).filter { $0.1 < 1 }.map { $0.0 }
                setGuide(missing.isEmpty ? "Nice!" :
                         "RIGHT stick: ↑ forward (along the nose), ↓ back, ← left, → right. Still to do: " + missing.joined(separator: ", "),
                         .rightStick)
            }
            done = vals.allSatisfy { $0 >= 1 }

        case .navigate(let pts):
            if s == .flying, navIndex < pts.count {
                let dv = pts[navIndex] - pos
                if simd_length(dv) <= 0.2 {
                    navIndex += 1
                    markers = markers.map {
                        var m = $0
                        m.status = m.id < navIndex ? .done : (m.id == navIndex ? .active : .pending)
                        return m
                    }
                    if navIndex < pts.count { showFlash("Checkpoint \(navIndex)/\(pts.count)") }
                }
            }
            setProgress(Float(navIndex) / Float(pts.count))
            if !groundGuide(s), navIndex < pts.count {
                let dv = pts[navIndex] - pos
                setGuide(String(format: "Fly to the glowing orb %d/%d – %.1f m away, ", navIndex + 1, pts.count, simd_length(dv)) + bearing(dv), .bothSticks)
            }
            done = navIndex >= pts.count

        case .land(let r):
            let horiz = (pos.x * pos.x + pos.z * pos.z).squareRoot()
            let onPad = horiz <= r
            zoneOK = onPad
            switch s {
            case .landed:
                if onPad { done = true }
                else { setGuide("Landed outside the pad – tap TAKE OFF and land on the blue circle.", .takeoff) }
            case .flying, .landing:
                if onPad {
                    setGuide(s == .flying ? "Over the pad – tap LAND (or lower the LEFT stick gently)." : "Landing…",
                             s == .flying ? .land : nil)
                } else {
                    setGuide(String(format: "Move over the blue pad first – it is %.1f m away, ", horiz) + bearing(SIMD3<Float>(-pos.x, 0, -pos.z)), .rightStick)
                }
            default:
                _ = groundGuide(s)
            }
            setProgress(done ? 1 : 0)

        case .disarm:
            if s == .disarmed { done = true }
            else if s.isAirborne { setGuide("Land first, then tap DISARM.", .land) }
            else { setGuide("Tap DISARM to finish.", .arm) }
            setProgress(done ? 1 : 0)
        }

        let t: String? = stepTime > 10 ? step.tip : nil
        if t != tip { tip = t }
        if done { complete(step) }
    }

    // MARK: Completion / scoring

    private func complete(_ step: Step) {
        guard let a = activity else { return }
        showFlash("✓ \(step.title) complete")
        if stepIndex + 1 >= a.steps.count {
            finish()
        } else {
            stepIndex += 1
            enterStep()
        }
    }

    private func finish() {
        guard let a = activity else { return }
        let stability: Int? = hoverTotal > 0.5 ? Int((hoverIn / hoverTotal * 100).rounded()) : nil
        var score: Int? = nil
        var newBest = false
        if !a.isTutorial {
            let penalty = Float(flight.collisions) * 8 + Float(flight.violations) * 4 + max(0, elapsed - a.parSeconds) / 4
            let s = max(0, Int((100 - penalty).rounded()))
            score = s
            newBest = s > (saved.best[a.id] ?? -1)
            if newBest { saved.best[a.id] = s }
        }
        if !saved.completed.contains(a.id) { saved.completed.append(a.id) }
        saved.save()

        report = Report(title: a.title, score: score, time: elapsed,
                        collisions: flight.collisions, violations: flight.violations,
                        stability: stability, isTutorial: a.isTutorial, newBest: newBest)
        markers = []; checklist = []; highlight = nil; tip = nil; flash = nil; flashUntil = nil
        hint = "Complete!"
    }

    // MARK: Helpers

    private func applyAltitudeBand(_ a: Activity, _ step: Step) {
        guard let band = a.altitudeBand, flight.state == .flying else { bandLatched = false; return }
        switch step.goal {
        case .hover, .directions: break
        default: return
        }
        let out = !band.contains(flight.position.y)
        if out && !bandLatched {
            bandLatched = true
            flight.registerViolation(String(format: "Altitude out of limits – stay between %.1f and %.1f m.", band.lowerBound, band.upperBound))
        }
        if !out { bandLatched = false }
    }

    /// Guidance for every state that is not "flying". Returns true if it set a guide.
    private func groundGuide(_ s: FlightState) -> Bool {
        switch s {
        case .disarmed: setGuide("Drone is disarmed – tap ARM first.", .arm)
        case .armed, .landed: setGuide("Tap TAKE OFF to start flying.", .takeoff)
        case .takingOff: setGuide("Taking off…", nil)
        case .landing: setGuide("Landing in progress – wait, then tap TAKE OFF.", nil)
        case .flying: return false
        }
        return true
    }

    private func driftGuide(pos: SIMD3<Float>, alt: Float, r: Float, horiz: Float) {
        if horiz > r {
            let corr = SIMD3<Float>(-pos.x, 0, -pos.z)
            let f = simd_dot(corr, flight.forward)
            let rr = simd_dot(corr, flight.right)
            let msg: String
            if abs(f) > abs(rr) {
                msg = f > 0 ? "push the RIGHT stick UP (forward)" : "pull the RIGHT stick DOWN (back)"
            } else {
                msg = rr > 0 ? "nudge the RIGHT stick RIGHT" : "nudge the RIGHT stick LEFT"
            }
            setGuide("Drifting out of the zone! " + msg.prefix(1).uppercased() + msg.dropFirst() + ".", .rightStick)
        } else {
            setGuide(pos.y < alt ? "Too low – nudge the LEFT stick UP." : "Too high – nudge the LEFT stick DOWN.", .leftStick)
        }
    }

    private func bearing(_ d: SIMD3<Float>) -> String {
        let f = simd_dot(d, flight.forward)
        let r = simd_dot(d, flight.right)
        var parts: [String] = []
        if f > 0.12 { parts.append("ahead") } else if f < -0.12 { parts.append("behind you") }
        if r > 0.12 { parts.append("to the right") } else if r < -0.12 { parts.append("to the left") }
        if d.y > 0.12 { parts.append("above") } else if d.y < -0.12 { parts.append("below") }
        return parts.isEmpty ? "right here" : parts.joined(separator: ", ")
    }

    private func setGuide(_ text: String, _ c: Control?) {
        if hint != text { hint = text }
        if highlight != c { highlight = c }
    }

    private func setProgress(_ p: Float) {
        if abs(p - progress) > 0.01 || (p == 0 && progress != 0) || (p >= 1 && progress < 1) { progress = p }
    }

    private func setChecklist(_ values: [Float]) {
        var list = checklist
        var changed = false
        for i in list.indices where i < values.count {
            let v = (min(values[i], 1) * 20).rounded() / 20
            if v != list[i].value { list[i].value = v; changed = true }
        }
        if changed { checklist = list }
    }

    private func showFlash(_ text: String) {
        flash = text
        flashUntil = elapsed + 2.5
    }
}
