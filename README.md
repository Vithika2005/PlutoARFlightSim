# Pluto AR Flight Simulator (iPhone · ARKit + RealityKit + SwiftUI)

A beginner drone-training simulator. The organiser-provided Pluto drone is placed on your real floor/table
through the iPhone camera (ARKit), flown with an on-screen virtual controller, and taught through a guided
7-stage tutorial plus 3 training missions. No physical drone and no network connection needed.

## Device requirements
- iPhone with ARKit world tracking (iPhone XS or newer). LiDAR (Pro models) is used automatically for occlusion.
- iOS 17+ . Developed/tested target: iPhone Pro (landscape).
- Mac with Xcode 16 or newer (Xcode 26 on M-series is fine), free Apple ID is enough.
- 2 m × 2 m of free floor or a table. Good light.

## Build & run (10 minutes)

### Option A – XcodeGen (recommended, creates the project for you)
```bash
brew install xcodegen          # one-time
cd PlutoARFlightSim            # folder containing project.yml
# edit project.yml: change com.yourname to something unique (e.g. com.vithika)
xcodegen generate
open PlutoARFlightSim.xcodeproj
```

### Option B – manual Xcode project
1. Xcode → File → New → Project → iOS **App**. Name `PlutoARFlightSim`, Interface **SwiftUI**, Language **Swift**.
2. Delete the template `ContentView.swift` and `PlutoARFlightSimApp.swift`.
3. Drag all `.swift` files from `PlutoARFlightSim/` into the project (tick *Copy items if needed*, target checked).
4. Target → **Info** tab → add `Privacy - Camera Usage Description` = "The camera shows the virtual Pluto drone in your room."
5. Target → General → Deployment: iOS 17.0, uncheck Portrait (keep Landscape Left/Right).
6. Build Settings → *Swift Language Version* = **Swift 5**.

### Then (both options)
1. Plug the iPhone into the Mac with a cable, unlock it, tap **Trust**.
2. iPhone: Settings → Privacy & Security → **Developer Mode** → On (phone restarts).
3. Xcode → target → **Signing & Capabilities** → tick *Automatically manage signing* → choose your **Team** (your Apple ID).
4. Pick your iPhone in the device menu at the top → press **▶ Run**.
5. First launch: iPhone → Settings → General → VPN & Device Management → trust your developer profile. Allow camera.

## Add the Pluto model
1. Convert the organiser's model to **USDZ** (Apple *Reality Converter*, free from developer.apple.com/augmented-reality/tools, handles OBJ/FBX/glTF; or Blender → File → Export → USD, choose `.usdz`).
2. Name it exactly `PlutoDrone.usdz` and drag it into `PlutoARFlightSim/Resources/` (or into the Xcode project, target ticked).
3. Run. The model is auto-scaled to 30 cm and centred on the floor.
4. Check the lights: **red light = front**. If the red light is not at the drone's nose, set `Config.modelYawOffsetDegrees` (90, 180, -90).
5. If the model has separate propeller nodes named *prop/rotor/blade*, set `Config.spinModelPropellers = true`.

Until the file is added the app shows a built-in placeholder quadcopter so you can test everything first.

## How to use
1. Menu opens at launch → pick **Guided Tutorial**, a **Mission**, or **Free flight**.
2. Sweep the phone over the floor until the cyan reticle appears → stand ~2 m back → **PLACE DRONE HERE**.
3. Follow the yellow-pulsing controls and the instruction card at the top.

## Virtual controller (Mode-2 layout, as in typical Pluto/Mode-2 apps – compare with the Pluto Controller app and adjust labels if different)
| Control | Action |
|---|---|
| Left stick ↑ / ↓ | Throttle – climb / descend (springs to centre = hold altitude) |
| Left stick ← / → | Yaw – rotate left / right |
| Right stick ↑ / ↓ | Pitch – forward / backward (along the nose) |
| Right stick ← / → | Roll – move left / right |
| ARM / DISARM | Arm motors (only on the ground) / disarm (only when landed) |
| TAKE OFF | Auto-lift to 0.5 m (needs ARMED) |
| LAND | Auto-descend and touch down |

## Flight state machine
```
DISARMED --ARM--> ARMED --TAKE OFF--> TAKING OFF --(0.5 m)--> FLYING <--> (hover = flying, speed≈0)
    ^                ^                                             |
    |                '------- TAKE OFF again ------- LANDED <--(touchdown)-- LANDING <--LAND--'
    '------------- DISARM (ground only) --------------'
```
Invalid operations are rejected with a warning (e.g. sticks while disarmed, TAKE OFF before ARM, DISARM in the air).
Other behaviour: altitude ceiling 2 m, 2 m flight radius, ground detection, hard-landing warning, pillar collisions,
simulated wind drift, velocity smoothing (stabilisation), body tilt following motion.

## Tutorial (every stage validated on real user actions)
1. Controller familiarization – move each stick in all 8 directions (checklist).
2. Arming – only completes when the drone is actually armed.
3. Takeoff – reach 0.8 m ± 0.1 m and hold 1 s.
4. Hovering – stay in the green hover zone 5 s (zone turns orange + corrective prompt when you drift; wind pushes you).
5. Directional movement – 0.25 m forward, back, left, right (measured in the drone's own frame).
6. Navigation – 4 glowing checkpoints in order.
7. Landing + disarming – land inside the pad circle, then DISARM.

Stuck for 10 s → a tip appears. Warnings/collisions appear as banners. Each stage gives completion feedback.

## Missions
1. **Takeoff & Landing** – arm, take off, steady flight 4 s, land on the pad, disarm.
2. **Hover & Directional Control** – hold 0.8 m, move 4 directions, return/settle, land; altitude limit 0.5–1.1 m.
3. **AR Navigation Challenge** – 5 checkpoints around 2 pillars, then land.

Score (missions) = 100 − 8/collision − 4/limit violation − 1 per 4 s over par time. Hover stability %, best scores and
completion are saved on the device.

## Code map
| File | What |
|---|---|
| `Config.swift` | All tunables (model name, scale, speeds, limits) |
| `FlightModel.swift` | State machine, simplified physics, wind, limits, collisions |
| `TrainingEngine.swift` | Goal validation, hints, checklists, scoring, saved progress |
| `Catalog.swift` | Tutorial + mission definitions |
| `ARFlightView.swift` | ARKit session, surface placement, model loading, AR markers/labels, tracking handling |
| `ContentView.swift` | HUD, virtual joysticks, buttons, menu, result card |
| `Tests/FlightModelTests.swift` | Unit tests of the flight logic |

## Testing evidence
- Unit tests: Xcode → **Product → Test** (⌘U) on any iPhone simulator (9 tests: arming rules, takeoff, no-move-while-disarmed, no-disarm-in-air, landing, direction, hover, boundary, collision).
- Manual test checklist (record a screen video on the iPhone: Control Centre → Screen Recording):
  - [ ] Place drone on floor, walk around it – stays anchored
  - [ ] Sticks before ARM → warning, no movement
  - [ ] ARM → TAKE OFF → reaches ~0.5 m
  - [ ] Tutorial stages 1–7 complete in order
  - [ ] Missions 1, 2, 3 complete; collision counted on a pillar
  - [ ] Cover the camera → "tracking" banner, simulation pauses; uncover → resumes
  - [ ] Walk a real object in front of the drone (LiDAR phones) → drone is occluded

## Known limitations
- iOS/ARKit only (no Android ARCore build). Flight physics are simplified, not a real quadcopter model.
- The Pluto Controller app was not available when this was written; the layout follows the common Mode-2 layout. Compare and adjust labels/buttons.
- The simulator is for education and does not replace supervised physical flight training.
- Tracking drift over long sessions can shift the anchor slightly – use *Re-place drone* (scope button).
- Not run in the iOS Simulator (no camera); use a real iPhone.

## Troubleshooting
- *"Developer Mode required"* → Settings → Privacy & Security → Developer Mode.
- *Black screen* → camera permission denied: Settings → Pluto AR Sim → Camera.
- *Actor-isolation errors (Xcode 26)* → Build Settings: Swift Language Version = Swift 5 and "Default Actor Isolation" = nonisolated.
- *Model too big / wrong way / floating* → `Config.droneSize`, `Config.modelYawOffsetDegrees`; make sure the USDZ is Y-up.
- *No reticle* → more light, move slowly, aim at a textured floor (not a plain glossy one).
