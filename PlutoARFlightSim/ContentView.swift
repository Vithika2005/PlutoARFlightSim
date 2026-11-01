import SwiftUI

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        ZStack {
            ARFlightView(flight: app.flight, engine: app.engine, status: app.ar)
                .ignoresSafeArea()
            HUDLayer(flight: app.flight, engine: app.engine, ar: app.ar)
        }
        .background(Color.black)
        .statusBarHidden(true)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
    }
}

// MARK: - HUD

struct HUDLayer: View {
    @ObservedObject var flight: FlightModel
    @ObservedObject var engine: TrainingEngine
    @ObservedObject var ar: ARStatus
    @State private var showMenu = true

    var body: some View {
        ZStack {
            VStack(spacing: 8) {
                topBar
                if engine.activity != nil { instructionCard }
                if let f = engine.flash {
                    Text(f).font(.subheadline.bold())
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Color.green.opacity(0.85), in: Capsule())
                }
                if let b = flight.banner {
                    Text(b.text).font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background((b.isError ? Color.red : Color.blue).opacity(0.85), in: Capsule())
                }
                Spacer(minLength: 0)
                if ar.isPlaced { controls } else { placement }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            if !ar.isPlaced && !ar.unsupported {
                Image(systemName: "plus.viewfinder")
                    .font(.system(size: 44, weight: .thin))
                    .foregroundColor(Color.white.opacity(0.8))
            }

            if let r = engine.report {
                Color.black.opacity(0.45).ignoresSafeArea()
                ReportCard(report: r,
                           onRetry: { engine.restart() },
                           onMenu: { engine.startFreeFlight(); showMenu = true })
            }
        }
        .foregroundColor(.white)
        .animation(.easeInOut(duration: 0.2), value: flight.banner)
        .sheet(isPresented: $showMenu) { MenuView(engine: engine, ar: ar) }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 8) {
            Button { showMenu = true } label: {
                Image(systemName: "line.3.horizontal").font(.title3).padding(8)
                    .background(Color.black.opacity(0.55), in: Circle())
            }
            Text(flight.state.rawValue).font(.caption.bold())
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(flight.state.color.opacity(0.9), in: Capsule())
            telemetry("ALT", String(format: "%.2f m", flight.hud.altitude))
            telemetry("SPD", String(format: "%.2f m/s", flight.hud.speed))
            telemetry("HDG", String(format: "%03.0f°", flight.hud.heading))
            telemetry("HOME", String(format: "%.2f m", flight.hud.homeDistance))
            Spacer()
            if let note = ar.trackingNote {
                Label(note, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).padding(6)
                    .background(Color.orange.opacity(0.85), in: Capsule())
            }
            if ar.isPlaced {
                Button { ar.resetRequest.send(); engine.restart() } label: {
                    Image(systemName: "scope").font(.title3).padding(8)
                        .background(Color.black.opacity(0.55), in: Circle())
                }
            }
        }
    }

    private func telemetry(_ name: String, _ value: String) -> some View {
        VStack(spacing: 0) {
            Text(name).font(.system(size: 9, weight: .bold)).foregroundColor(Color.white.opacity(0.7))
            Text(value).font(.system(size: 13, weight: .semibold, design: .monospaced))
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Instruction card

    private var stepHeader: String {
        guard let a = engine.activity else { return "" }
        let n = engine.stepIndex + 1
        return "\(a.title.uppercased())  ·  STEP \(n)/\(a.steps.count)  ·  \(a.steps[engine.stepIndex].title)"
    }

    private var instructionCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(stepHeader).font(.system(size: 10, weight: .bold)).foregroundColor(Color.white.opacity(0.75))
            Text(engine.hint).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            if let tip = engine.tip {
                Text("💡 " + tip).font(.caption).foregroundColor(Color.yellow)
            }
            if !engine.checklist.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 6)], spacing: 4) {
                    ForEach(engine.checklist) { c in
                        HStack(spacing: 3) {
                            Image(systemName: c.value >= 1 ? "checkmark.circle.fill" : "circle")
                            Text(c.label)
                            if c.value > 0 && c.value < 1 { Text("\(Int(c.value * 100))%") }
                        }
                        .font(.caption2.bold())
                        .foregroundColor(c.value >= 1 ? Color.green : Color.white.opacity(0.5 + Double(c.value) * 0.4))
                    }
                }
            }
            ProgressView(value: Double(engine.progress)).tint(Color.green)
        }
        .padding(10)
        .frame(maxWidth: 560, alignment: .leading)
        .background(Color.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: Virtual controller

    private var controls: some View {
        HStack(alignment: .bottom) {
            stickPad(title: "THROTTLE ↕  ·  YAW ↔",
                     highlighted: engine.highlight == .leftStick || engine.highlight == .bothSticks) { x, y in
                flight.input.yaw = shaped(x)
                flight.input.throttle = shaped(y)
            }
            Spacer(minLength: 8)
            VStack(spacing: 8) {
                ControlButton(title: flight.state == .disarmed ? "ARM" : "DISARM",
                              color: flight.state == .disarmed ? .green : .red,
                              highlighted: engine.highlight == .arm) { flight.toggleArm() }
                HStack(spacing: 8) {
                    ControlButton(title: "TAKE OFF", color: .blue,
                                  highlighted: engine.highlight == .takeoff) { flight.takeOff() }
                    ControlButton(title: "LAND", color: .orange,
                                  highlighted: engine.highlight == .land) { flight.land() }
                }
            }
            Spacer(minLength: 8)
            stickPad(title: "PITCH ↕  ·  ROLL ↔",
                     highlighted: engine.highlight == .rightStick || engine.highlight == .bothSticks) { x, y in
                flight.input.roll = shaped(x)
                flight.input.pitch = shaped(y)
            }
        }
    }

    private func stickPad(title: String, highlighted: Bool, onChange: @escaping (CGFloat, CGFloat) -> Void) -> some View {
        VStack(spacing: 4) {
            Joystick(size: 150, highlighted: highlighted, onChange: onChange)
            Text(title).font(.system(size: 10, weight: .bold)).foregroundColor(Color.white.opacity(0.85))
        }
    }

    /// Dead-zone + gentle expo curve: fine control near the centre (needed to fight the wind), full range at the edge.
    private func shaped(_ v: CGFloat) -> Float {
        let a = Float(v)
        let m = abs(a)
        if m < 0.04 { return 0 }
        return (0.6 * m * m + 0.4 * m) * (a < 0 ? -1 : 1)
    }

    // MARK: Placement

    private var placement: some View {
        VStack(spacing: 8) {
            if ar.unsupported {
                Text("ARKit world tracking is not supported here. Run on a real iPhone (not the Simulator).")
                    .font(.callout.bold()).padding(10)
                    .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
            } else {
                Text(ar.surfaceReady ? "Surface found – stand about 2 m back, then place the drone."
                                     : "Slowly sweep the phone over the floor or a table…")
                    .font(.callout.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.black.opacity(0.6), in: Capsule())
                Button { ar.placeRequest.send() } label: {
                    Text("PLACE DRONE HERE").font(.headline).padding(.horizontal, 24).padding(.vertical, 12)
                        .background(ar.surfaceReady ? Color.green : Color.gray, in: Capsule())
                }
                .disabled(!ar.surfaceReady)
            }
        }
        .padding(.bottom, 10)
    }
}

// MARK: - Joystick

struct Joystick: View {
    var size: CGFloat = 150
    var highlighted = false
    var onChange: (CGFloat, CGFloat) -> Void       // x right+, y up+  (range -1...1)
    @State private var knob: CGSize = .zero

    var body: some View {
        let r = size / 2
        let kr = size * 0.2
        ZStack {
            Circle().fill(Color.black.opacity(0.35))
            Circle().stroke(Color.white.opacity(0.7), lineWidth: 2)
            Rectangle().fill(Color.white.opacity(0.25)).frame(width: 1, height: size * 0.8)
            Rectangle().fill(Color.white.opacity(0.25)).frame(width: size * 0.8, height: 1)
            Circle().fill(Color.white.opacity(0.9)).frame(width: kr * 2, height: kr * 2).offset(knob)
            if highlighted { HighlightRing(shape: Circle()) }
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let maxR = r - kr
                    var dx = v.location.x - r
                    var dy = v.location.y - r
                    let d = (dx * dx + dy * dy).squareRoot()
                    if d > maxR { dx *= maxR / d; dy *= maxR / d }
                    knob = CGSize(width: dx, height: dy)
                    onChange(dx / maxR, -dy / maxR)
                }
                .onEnded { _ in
                    withAnimation(.spring(response: 0.18, dampingFraction: 0.7)) { knob = .zero }
                    onChange(0, 0)
                }
        )
    }
}

struct ControlButton: View {
    let title: String
    let color: Color
    var highlighted = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 15, weight: .heavy)).foregroundColor(.white)
                .frame(minWidth: 84, minHeight: 44).padding(.horizontal, 8)
                .background(color.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    if highlighted { HighlightRing(shape: RoundedRectangle(cornerRadius: 12)) }
                }
        }
        .buttonStyle(.plain)
    }
}

/// Pulsing yellow ring – tells the learner which control to use next.
struct HighlightRing<S: Shape>: View {
    let shape: S
    @State private var on = false
    var body: some View {
        shape.stroke(Color.yellow, lineWidth: 4)
            .opacity(on ? 1 : 0.25)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { on = true }
            }
    }
}

// MARK: - Result card

struct ReportCard: View {
    let report: Report
    let onRetry: () -> Void
    let onMenu: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text(report.isTutorial ? "Tutorial complete! 🎉" : "Mission complete! 🎉").font(.title2.bold())
            Text(report.title).font(.subheadline)
            if let s = report.score {
                Text("Score \(s)/100" + (report.newBest ? "  ★ new best" : "")).font(.title.bold())
            }
            Text(String(format: "Time %.0f s", report.time))
            Text("Collisions: \(report.collisions)   ·   Limit violations: \(report.violations)")
            if let st = report.stability { Text("Hover stability: \(st)%") }
            HStack(spacing: 12) {
                Button("Retry", action: onRetry)
                Button("Menu", action: onMenu)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 6)
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .foregroundColor(.white)
    }
}

// MARK: - Menu

struct MenuView: View {
    @ObservedObject var engine: TrainingEngine
    @ObservedObject var ar: ARStatus
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Guided tutorial") { row(Catalog.tutorial) }
                Section("Training missions") {
                    ForEach(Catalog.missions) { row($0) }
                }
                Section("Practice") {
                    Button { engine.startFreeFlight(); dismiss() } label: {
                        Label("Free flight (sandbox)", systemImage: "airplane")
                    }
                }
                Section("Tools") {
                    Button { ar.resetRequest.send(); engine.restart(); dismiss() } label: {
                        Label("Re-place drone", systemImage: "scope")
                    }
                    Button { engine.skipStep(); dismiss() } label: {
                        Label("Skip current stage (demo / debug)", systemImage: "forward.end")
                    }
                    Button(role: .destructive) { engine.resetProgress() } label: {
                        Label("Reset saved progress", systemImage: "trash")
                    }
                }
                Section("Controller layout") {
                    Text("LEFT stick: ↑↓ throttle (climb / descend), ←→ yaw (rotate).")
                    Text("RIGHT stick: ↑↓ pitch (forward / back), ←→ roll (sideways).")
                    Text("Centre the sticks to hover. ARM → TAKE OFF → fly → LAND → DISARM.")
                }
                .font(.footnote)
            }
            .navigationTitle("Pluto AR Flight Sim")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } }
            }
        }
    }

    @ViewBuilder
    private func row(_ a: Activity) -> some View {
        Button { engine.start(a); dismiss() } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(a.title).font(.headline)
                    Text(a.summary).font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                if let b = engine.saved.best[a.id] { Text("Best \(b)").font(.caption) }
                if engine.saved.completed.contains(a.id) {
                    Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
                }
            }
        }
    }
}
