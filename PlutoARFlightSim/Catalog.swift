import Foundation
import simd

/// The guided tutorial and the three training missions.
/// All positions are metres relative to the spot where the drone was placed
/// (x = right, y = up, -z = ahead of the drone at start).
enum Catalog {
    private static func p(_ x: Float, _ y: Float, _ z: Float) -> SIMD3<Float> { SIMD3<Float>(x, y, z) }

    // Reusable steps
    private static let armStep = Step(
        title: "Arm", instruction: "Tap ARM (green button) to arm the motors.",
        tip: "The ARM button is in the bottom centre. The drone will not fly until it is armed.", goal: .arm)

    private static func takeoffStep(_ alt: Float) -> Step {
        Step(title: "Takeoff", instruction: "Tap TAKE OFF, then climb into the green zone.",
             tip: "TAKE OFF lifts the drone to 0.5 m by itself. After that, push the LEFT stick up/down to reach the target altitude.",
             goal: .takeoff(altitude: alt))
    }

    private static func hoverStep(_ title: String, _ alt: Float, _ r: Float, _ s: Float) -> Step {
        Step(title: title, instruction: "Keep the drone inside the green zone.",
             tip: "Small, gentle stick movements work best. Let go of the stick to stop – the drone holds position (the wind will push it slowly).",
             goal: .hover(altitude: alt, radius: r, seconds: s))
    }

    private static let landStep = Step(
        title: "Land on the pad", instruction: "Fly over the blue pad and land.",
        tip: "Move over the pad with the RIGHT stick, then tap LAND. Lowering the LEFT stick slowly also works.",
        goal: .land(padRadius: 0.25))

    private static let disarmStep = Step(
        title: "Disarm", instruction: "Tap DISARM.",
        tip: "The same button that armed the drone (bottom centre) now says DISARM.", goal: .disarm)

    // MARK: Guided tutorial (7 stages)

    static let tutorial = Activity(
        id: "tutorial",
        title: "Guided Flight Tutorial",
        summary: "7 stages: controls → arming → takeoff → hover → movement → navigation → landing",
        steps: [
            Step(title: "Stage 1 · Controller familiarization",
                 instruction: "Meet the controller. LEFT stick = throttle (↑↓) + yaw (←→). RIGHT stick = pitch (↑↓) + roll (←→).",
                 tip: "The drone is disarmed, so it will not move yet – just move each stick fully in all four directions.",
                 goal: .practiceSticks),
            Step(title: "Stage 2 · Arming",
                 instruction: "Tap ARM (green button) to arm the motors.",
                 tip: "Real drones ignore the sticks until armed. Tap the green ARM button, bottom centre.",
                 goal: .arm),
            Step(title: "Stage 3 · Takeoff",
                 instruction: "Tap TAKE OFF, then climb into the green zone at 0.8 m.",
                 tip: "TAKE OFF lifts the drone to 0.5 m by itself. Push the LEFT stick up to reach 0.8 m, then release it.",
                 goal: .takeoff(altitude: 0.8)),
            Step(title: "Stage 4 · Hovering",
                 instruction: "Hold the drone inside the green zone for 5 seconds.",
                 tip: "Wind pushes the drone. Use small RIGHT-stick corrections and release the stick to stop.",
                 goal: .hover(altitude: 0.8, radius: 0.2, seconds: 5)),
            Step(title: "Stage 5 · Directional movement",
                 instruction: "Fly forward, back, left and right.",
                 tip: "Forward means where the drone's red nose light points – after yawing, forward changes too.",
                 goal: .directions(distance: 0.25)),
            Step(title: "Stage 6 · Navigation",
                 instruction: "Fly through the glowing checkpoints in order.",
                 tip: "Combine LEFT stick (height, turn) and RIGHT stick (move). The hint tells you where the next orb is.",
                 goal: .navigate(points: [p(0, 0.8, -0.6), p(0.6, 0.9, -0.9), p(-0.5, 0.8, -1.0), p(0, 0.7, -0.4)])),
            Step(title: "Stage 7a · Landing",
                 instruction: "Fly over the blue pad and land.",
                 tip: "Move over the pad with the RIGHT stick, then tap LAND.",
                 goal: .land(padRadius: 0.25)),
            Step(title: "Stage 7b · Disarming",
                 instruction: "Tap DISARM to finish.",
                 tip: "The same button that armed the drone now says DISARM.",
                 goal: .disarm)
        ],
        drift: 0.05, parSeconds: 600, isTutorial: true)

    // MARK: Missions

    /// Mission 1 – Takeoff & Landing
    static let mission1 = Activity(
        id: "m1",
        title: "Mission 1 · Takeoff & Landing",
        summary: "Arm, take off, fly steady for 4 s, land on the pad, disarm",
        steps: [armStep, takeoffStep(0.6), hoverStep("Controlled flight", 0.6, 0.25, 4), landStep, disarmStep],
        drift: 0.03, parSeconds: 60)

    /// Mission 2 – Hovering & Directional Control (altitude band is a hard limit)
    static let mission2 = Activity(
        id: "m2",
        title: "Mission 2 · Hover & Directional Control",
        summary: "Hold 0.8 m, move in all four directions, return and settle – stay between 0.5 and 1.1 m",
        steps: [
            armStep, takeoffStep(0.8),
            hoverStep("Stabilise", 0.8, 0.2, 4),
            Step(title: "Directional moves", instruction: "Fly forward, back, left and right.",
                 tip: "Keep the altitude between 0.5 and 1.1 m while you move.", goal: .directions(distance: 0.3)),
            hoverStep("Return and settle", 0.8, 0.2, 3),
            landStep, disarmStep
        ],
        drift: 0.06, altitudeBand: 0.5...1.1, parSeconds: 120)

    /// Mission 3 – AR Navigation Challenge (5 checkpoints, 2 pillars)
    static let mission3 = Activity(
        id: "m3",
        title: "Mission 3 · AR Navigation Challenge",
        summary: "Fly through 5 checkpoints around 2 pillars, then land",
        steps: [
            armStep, takeoffStep(0.7),
            Step(title: "Checkpoint course", instruction: "Fly through the glowing orbs in order – avoid the orange pillars.",
                 tip: "Pillars are 1.3 m tall – fly around them, not over them.",
                 goal: .navigate(points: [p(0, 0.7, -0.7), p(0.7, 0.9, -1.1), p(0, 1.0, -1.5), p(-0.7, 0.8, -0.9), p(-0.35, 0.6, -0.1)])),
            landStep, disarmStep
        ],
        obstacles: [Obstacle(position: p(0.35, 0, -0.9), radius: 0.08, height: 1.3),
                    Obstacle(position: p(-0.35, 0, -1.2), radius: 0.08, height: 1.3)],
        drift: 0.04, parSeconds: 150)

    static let missions: [Activity] = [mission1, mission2, mission3]
}
