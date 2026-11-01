import SwiftUI
import RealityKit
import ARKit
import Combine

// MARK: - Shared AR status (UI <-> AR layer)

final class ARStatus: ObservableObject {
    @Published var isPlaced = false
    @Published var surfaceReady = false
    @Published var trackingNote: String?
    @Published var unsupported = false
    let placeRequest = PassthroughSubject<Void, Never>()
    let resetRequest = PassthroughSubject<Void, Never>()
}

// MARK: - SwiftUI wrapper

struct ARFlightView: UIViewRepresentable {
    let flight: FlightModel
    let engine: TrainingEngine
    let status: ARStatus

    func makeCoordinator() -> ARCoordinator {
        ARCoordinator(flight: flight, engine: engine, status: status)
    }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}

// MARK: - Material helpers

func glow(_ color: UIColor, alpha: CGFloat) -> UnlitMaterial {
    var m = UnlitMaterial(color: color)
    m.blending = .transparent(opacity: .init(floatLiteral: Float(alpha)))
    return m
}

/// Flat translucent disc (a squashed sphere – works on every RealityKit version).
func disc(radius: Float, color: UIColor, alpha: CGFloat) -> ModelEntity {
    let e = ModelEntity(mesh: .generateSphere(radius: radius), materials: [glow(color, alpha: alpha)])
    e.scale = SIMD3<Float>(1, 0.02, 1)
    return e
}

func makeLabel(_ text: String, size: Float, color: UIColor) -> Entity {
    let mesh = MeshResource.generateText(text, extrusionDepth: 0.001,
                                         font: .systemFont(ofSize: CGFloat(size), weight: .bold))
    let model = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: color)])
    let c = mesh.bounds.center
    model.position = SIMD3<Float>(-c.x, -c.y, 0)
    let holder = Entity()
    holder.addChild(model)
    return holder
}

// MARK: - Coordinator: owns the AR session, the scene and the per-frame loop

final class ARCoordinator: NSObject, ARSessionDelegate {
    private let flight: FlightModel
    private let engine: TrainingEngine
    private let status: ARStatus
    private weak var arView: ARView?

    // Scene graph:  anchor → world → { droneRoot → tilt → model, pad, shadow, altLine, label, obstacles, markers }
    private let world = Entity()
    private let droneRoot = Entity()
    private let tilt = Entity()
    private let label = Entity()
    private let markerRoot = Entity()
    private let obstacleRoot = Entity()
    private let reticleAnchor = AnchorEntity(world: SIMD3<Float>(0, 0, 0))
    private let reticle = Entity()

    private var anchor: AnchorEntity?
    private var shadow: ModelEntity?
    private var altLine: ModelEntity?
    private var propellers: [Entity] = []
    private var markerNodes: [Int: [ModelEntity]] = [:]
    private var markerLabels: [Entity] = []
    private var currentMarkers: [Marker] = []
    private var zoneOK = true
    private var lastLabelText = ""
    private var labelClock: Float = 0
    private var cancellables = Set<AnyCancellable>()
    private var updateSub: Cancellable?

    init(flight: FlightModel, engine: TrainingEngine, status: ARStatus) {
        self.flight = flight
        self.engine = engine
        self.status = status
        super.init()
    }

    // MARK: Setup

    func attach(to view: ARView) {
        arView = view
        guard ARWorldTrackingConfiguration.isSupported else {
            DispatchQueue.main.async { self.status.unsupported = true }
            return
        }
        view.automaticallyConfigureSession = false
        view.session.delegate = self
        runSession()

        let coach = ARCoachingOverlayView()
        coach.session = view.session
        coach.goal = .horizontalPlane
        coach.activatesAutomatically = true
        coach.frame = view.bounds
        coach.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(coach)

        // Placement reticle
        view.scene.addAnchor(reticleAnchor)
        reticleAnchor.addChild(reticle)
        reticle.addChild(disc(radius: 0.15, color: .systemCyan, alpha: 0.45))
        reticle.addChild(disc(radius: 0.02, color: .white, alpha: 0.9))

        buildScene()

        updateSub = view.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            self?.onUpdate(Float(event.deltaTime))
        }
        status.placeRequest.sink { [weak self] in self?.place() }.store(in: &cancellables)
        status.resetRequest.sink { [weak self] in self?.unplace() }.store(in: &cancellables)
        engine.$markers.sink { [weak self] m in
            self?.currentMarkers = m
            self?.rebuildMarkers()
        }.store(in: &cancellables)
        engine.$obstacles.sink { [weak self] o in self?.rebuildObstacles(o) }.store(in: &cancellables)
        engine.$zoneOK.sink { [weak self] ok in
            self?.zoneOK = ok
            self?.recolor()
        }.store(in: &cancellables)
    }

    private func runSession() {
        guard let view = arView else { return }
        let cfg = ARWorldTrackingConfiguration()
        cfg.planeDetection = [.horizontal]
        cfg.environmentTexturing = .automatic
        // LiDAR (iPhone Pro): real furniture/walls hide the virtual drone → much better AR integration
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            cfg.sceneReconstruction = .mesh
            view.environment.sceneUnderstanding.options.insert(.occlusion)
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
            cfg.frameSemantics.insert(.personSegmentationWithDepth)
        }
        view.session.run(cfg)
    }

    // MARK: Placement

    private func updateReticle(_ view: ARView) {
        let c = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        if let hit = view.raycast(from: c, allowing: .estimatedPlane, alignment: .horizontal).first {
            reticle.isEnabled = true
            reticle.setTransformMatrix(hit.worldTransform, relativeTo: nil)
            if !status.surfaceReady { status.surfaceReady = true }
        } else {
            reticle.isEnabled = false
            if status.surfaceReady { status.surfaceReady = false }
        }
    }

    private func place() {
        guard let view = arView, anchor == nil else { return }
        let c = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        guard let hit = view.raycast(from: c, allowing: .estimatedPlane, alignment: .horizontal).first else {
            flight.notify("No surface found yet – move the phone slowly over the floor or a table.", error: true)
            return
        }
        let t = hit.worldTransform
        let pos = SIMD3<Float>(t.columns.3.x, t.columns.3.y + 0.01, t.columns.3.z)

        // Face the drone away from the user (its nose points where the camera looks)
        let rot = view.cameraTransform.rotation
        let f = rot.act(SIMD3<Float>(0, 0, -1))
        var fh = SIMD2<Float>(f.x, f.z)
        if simd_length(fh) < 0.3 {                       // looking almost straight down: use the phone's "up" edge
            let u = rot.act(SIMD3<Float>(0, 1, 0))
            fh = SIMD2<Float>(u.x, u.z)
        }
        let yaw = atan2(-fh.x, -fh.y)

        var tr = Transform()
        tr.translation = pos
        tr.rotation = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
        let a = AnchorEntity(world: tr.matrix)
        a.addChild(world)
        view.scene.addAnchor(a)
        anchor = a
        reticle.isEnabled = false
        status.isPlaced = true
        flight.notify("Drone placed. Walk around it – stay 1–2 m back.")
    }

    private func unplace() {
        guard let view = arView, let a = anchor else { return }
        world.removeFromParent()
        view.scene.removeAnchor(a)
        anchor = nil
        status.isPlaced = false
    }

    // MARK: Scene construction

    private func buildScene() {
        loadDrone()
        droneRoot.addChild(tilt)
        world.addChild(droneRoot)

        let pad = disc(radius: 0.25, color: .systemBlue, alpha: 0.22)
        pad.position.y = 0.001
        world.addChild(pad)

        let sh = disc(radius: 0.1, color: .black, alpha: 0.35)
        world.addChild(sh)
        shadow = sh

        let line = ModelEntity(mesh: .generateBox(size: SIMD3<Float>(0.004, 1, 0.004)),
                               materials: [glow(.systemCyan, alpha: 0.7)])
        world.addChild(line)
        altLine = line

        world.addChild(label)
        world.addChild(obstacleRoot)
        world.addChild(markerRoot)
    }

    private func loadDrone() {
        let yawFix = simd_quatf(angle: Config.modelYawOffsetDegrees * .pi / 180, axis: SIMD3<Float>(0, 1, 0))
        if let model = try? Entity.load(named: Config.modelName) {
            model.orientation = yawFix
            let b0 = model.visualBounds(relativeTo: nil)
            let maxDim = max(b0.extents.x, b0.extents.z)
            if maxDim > 0.0001 { model.scale = SIMD3<Float>(repeating: Config.droneSize / maxDim) }
            tilt.addChild(model)
            let b = model.visualBounds(relativeTo: tilt)
            model.position = SIMD3<Float>(-b.center.x, -b.min.y, -b.center.z)   // centre on origin, sit on the floor
            if Config.spinModelPropellers { propellers = findPropellers(in: model) }
        } else {
            buildFallbackDrone()   // keeps the app runnable until PlutoDrone.usdz is added
        }
        // Navigation lights: RED = front (nose), WHITE = rear. Use them to check model orientation.
        let front = ModelEntity(mesh: .generateSphere(radius: 0.012), materials: [UnlitMaterial(color: .systemRed)])
        front.position = SIMD3<Float>(0, 0.07, -Config.droneSize * 0.5)
        let rear = ModelEntity(mesh: .generateSphere(radius: 0.012), materials: [UnlitMaterial(color: .white)])
        rear.position = SIMD3<Float>(0, 0.07, Config.droneSize * 0.5)
        tilt.addChild(front)
        tilt.addChild(rear)
    }

    private func findPropellers(in e: Entity) -> [Entity] {
        var out: [Entity] = []
        let n = e.name.lowercased()
        if n.contains("prop") || n.contains("rotor") || n.contains("blade") { out.append(e) }
        for c in e.children { out += findPropellers(in: c) }
        return out
    }

    private func buildFallbackDrone() {
        let body = ModelEntity(mesh: .generateBox(size: SIMD3<Float>(0.09, 0.03, 0.09), cornerRadius: 0.012),
                               materials: [SimpleMaterial(color: .darkGray, isMetallic: true)])
        body.position.y = 0.04
        tilt.addChild(body)

        for angle in [Float.pi / 4, -Float.pi / 4] {
            let arm = ModelEntity(mesh: .generateBox(size: SIMD3<Float>(0.26, 0.012, 0.02), cornerRadius: 0.004),
                                  materials: [SimpleMaterial(color: .gray, isMetallic: false)])
            arm.position.y = 0.04
            arm.orientation = simd_quatf(angle: angle, axis: SIMD3<Float>(0, 1, 0))
            tilt.addChild(arm)
        }

        let corners: [(Float, Float)] = [(-1, -1), (1, -1), (1, 1), (-1, 1)]
        for c in corners {
            let motor = ModelEntity(mesh: .generateSphere(radius: 0.016),
                                    materials: [SimpleMaterial(color: .black, isMetallic: true)])
            motor.position = SIMD3<Float>(c.0 * 0.092, 0.05, c.1 * 0.092)
            tilt.addChild(motor)

            let prop = Entity()
            prop.position = SIMD3<Float>(c.0 * 0.092, 0.064, c.1 * 0.092)
            let blade = ModelEntity(mesh: .generateBox(size: SIMD3<Float>(0.12, 0.003, 0.014), cornerRadius: 0.001),
                                    materials: [glow(.white, alpha: 0.85)])
            prop.addChild(blade)
            prop.addChild(disc(radius: 0.06, color: .white, alpha: 0.12))
            tilt.addChild(prop)
            propellers.append(prop)
        }
    }

    // MARK: Markers & obstacles

    private func rebuildMarkers() {
        markerRoot.children.removeAll()
        markerNodes.removeAll()
        markerLabels.removeAll()

        for m in currentMarkers {
            let holder = Entity()
            holder.position = m.position
            var nodes: [ModelEntity] = []
            var labelY: Float = 0.25

            switch m.kind {
            case .orb:
                let orb = ModelEntity(mesh: .generateSphere(radius: m.radius), materials: [])
                holder.addChild(orb)
                nodes = [orb]
                labelY = m.radius + 0.08
            case .zone:
                let lens = ModelEntity(mesh: .generateSphere(radius: m.radius), materials: [])
                lens.scale = SIMD3<Float>(1, 0.02, 1)
                let bubble = ModelEntity(mesh: .generateSphere(radius: m.radius), materials: [])
                holder.addChild(lens)
                holder.addChild(bubble)
                nodes = [lens, bubble]
                labelY = m.radius + 0.08
            case .pad:
                let d = ModelEntity(mesh: .generateSphere(radius: m.radius), materials: [])
                d.scale = SIMD3<Float>(1, 0.02, 1)
                holder.position.y += 0.004
                holder.addChild(d)
                nodes = [d]
                labelY = 0.15
            }

            let lbl = Entity()
            lbl.position = SIMD3<Float>(0, labelY, 0)
            lbl.addChild(makeLabel(m.label, size: 0.05, color: .white))
            holder.addChild(lbl)
            markerLabels.append(lbl)

            markerNodes[m.id] = nodes
            markerRoot.addChild(holder)
        }
        recolor()
    }

    private func recolor() {
        for m in currentMarkers {
            guard let nodes = markerNodes[m.id] else { continue }
            let alphas: [CGFloat] = m.kind == .zone ? [0.35, 0.10] : (m.kind == .pad ? [0.5] : [0.38])
            let k: CGFloat = m.status == .active ? 1 : (m.status == .pending ? 0.5 : 0.2)
            let base = baseColor(m)
            for (i, n) in nodes.enumerated() {
                n.model?.materials = [glow(base, alpha: alphas[min(i, alphas.count - 1)] * k)]
            }
        }
    }

    private func baseColor(_ m: Marker) -> UIColor {
        switch m.status {
        case .done: return .systemTeal
        case .pending: return .white
        case .active:
            switch m.kind {
            case .orb: return .systemGreen
            case .zone: return zoneOK ? .systemGreen : .systemOrange
            case .pad: return zoneOK ? .systemCyan : .systemOrange
            }
        }
    }

    private func rebuildObstacles(_ obs: [Obstacle]) {
        obstacleRoot.children.removeAll()
        for o in obs {
            let pillar = ModelEntity(
                mesh: .generateBox(size: SIMD3<Float>(o.radius * 2, o.height, o.radius * 2), cornerRadius: o.radius * 0.95),
                materials: [glow(.systemOrange, alpha: 0.85)])
            pillar.position = SIMD3<Float>(o.position.x, o.height / 2, o.position.z)
            obstacleRoot.addChild(pillar)
        }
    }

    // MARK: Per-frame loop

    private func onUpdate(_ dt: Float) {
        guard let view = arView else { return }
        flight.expireBanner()
        guard anchor != nil else {
            updateReticle(view)
            return
        }
        flight.step(dt)
        engine.update(dt: dt)
        render(dt, view)
    }

    private func render(_ dt: Float, _ view: ARView) {
        let p = flight.position
        droneRoot.position = p
        droneRoot.orientation = simd_quatf(angle: flight.yaw, axis: SIMD3<Float>(0, 1, 0))
        tilt.orientation = simd_quatf(angle: -flight.tiltForward, axis: SIMD3<Float>(1, 0, 0))
                         * simd_quatf(angle: -flight.tiltRight, axis: SIMD3<Float>(0, 0, 1))

        // Propellers: stopped when disarmed, idle when armed/landed, fast in the air
        let rate: Float
        switch flight.state {
        case .disarmed: rate = 0
        case .armed, .landed: rate = 12
        default: rate = 70
        }
        for (i, prop) in propellers.enumerated() {
            let dir: Float = i % 2 == 0 ? 1 : -1
            prop.orientation = simd_quatf(angle: rate * dt * dir, axis: SIMD3<Float>(0, 1, 0)) * prop.orientation
        }

        // Position / altitude indicators
        shadow?.position = SIMD3<Float>(p.x, 0.002, p.z)
        let s = max(0.4, 1 - p.y * 0.5)
        shadow?.scale = SIMD3<Float>(s, 0.02, s)
        altLine?.position = SIMD3<Float>(p.x, p.y / 2, p.z)
        altLine?.scale = SIMD3<Float>(1, max(p.y, 0.001), 1)

        // State + altitude label above the drone
        label.position = SIMD3<Float>(p.x, p.y + 0.2, p.z)
        labelClock += dt
        if labelClock > 0.25 {
            labelClock = 0
            let text = String(format: "%@ · %.1f m", flight.state.rawValue, p.y)
            if text != lastLabelText {
                lastLabelText = text
                label.children.removeAll()
                label.addChild(makeLabel(text, size: 0.045, color: flight.state.uiColor))
            }
        }

        // Billboards
        let cam = view.cameraTransform.translation
        face(label, toward: cam)
        for l in markerLabels { face(l, toward: cam) }
    }

    private func face(_ e: Entity, toward cam: SIMD3<Float>) {
        let p = e.position(relativeTo: nil)
        let a = atan2(cam.x - p.x, cam.z - p.z)
        e.setOrientation(simd_quatf(angle: a, axis: SIMD3<Float>(0, 1, 0)), relativeTo: nil)
    }

    // MARK: ARSessionDelegate – tracking interruptions handled gracefully

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        var note: String?
        var pause = false
        switch camera.trackingState {
        case .normal:
            note = nil
        case .notAvailable:
            note = "AR tracking unavailable – simulation paused"
            pause = true
        case .limited(let reason):
            switch reason {
            case .initializing: note = "Starting AR – move the phone slowly"
            case .excessiveMotion: note = "Moving too fast – slow down"
            case .insufficientFeatures: note = "Not enough detail – improve lighting / point at a textured surface"
            case .relocalizing: note = "Relocalizing… simulation paused"; pause = true
            @unknown default: note = "Limited AR tracking"
            }
        }
        DispatchQueue.main.async {
            self.status.trackingNote = note
            self.flight.paused = pause
        }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        DispatchQueue.main.async {
            self.flight.paused = true
            self.status.trackingNote = "AR session interrupted"
        }
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        DispatchQueue.main.async {
            self.flight.paused = false      // tracking callback pauses again if still relocalizing
            self.status.trackingNote = "Relocalizing…"
        }
    }

    func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool { true }

    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async {
            self.status.trackingNote = "AR error: \(error.localizedDescription)"
        }
    }
}
