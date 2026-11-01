import XCTest
@testable import PlutoARFlightSim

final class FlightModelTests: XCTestCase {

    private func run(_ m: FlightModel, seconds: Float) {
        var t: Float = 0
        while t < seconds { m.step(0.016); t += 0.016 }
    }

    private func flyingModel() -> FlightModel {
        let m = FlightModel()
        m.toggleArm()
        m.takeOff()
        run(m, seconds: 3)
        return m
    }

    func testCannotTakeOffWhenDisarmed() {
        let m = FlightModel()
        m.takeOff()
        XCTAssertEqual(m.state, .disarmed)
    }

    func testArmThenTakeOffReachesFlying() {
        let m = FlightModel()
        m.toggleArm()
        XCTAssertEqual(m.state, .armed)
        m.takeOff()
        run(m, seconds: 3)
        XCTAssertEqual(m.state, .flying)
        XCTAssertGreaterThan(m.position.y, 0.45)
    }

    func testNoMovementWhileDisarmed() {
        let m = FlightModel()
        m.input = StickInput(throttle: 1, yaw: 0, pitch: 1, roll: 0)
        run(m, seconds: 1)
        XCTAssertEqual(m.position, SIMD3<Float>(0, 0, 0))
    }

    func testCannotDisarmInFlight() {
        let m = flyingModel()
        m.toggleArm()
        XCTAssertEqual(m.state, .flying)
    }

    func testLandingEndsLandedOnGround() {
        let m = flyingModel()
        m.land()
        run(m, seconds: 6)
        XCTAssertEqual(m.state, .landed)
        XCTAssertEqual(m.position.y, 0, accuracy: 0.001)
    }

    func testForwardStickMovesAlongNose() {
        let m = flyingModel()
        m.input.pitch = 1
        run(m, seconds: 1)
        XCTAssertLessThan(m.position.z, -0.1)   // yaw 0 → nose points to -Z
    }

    func testCentredSticksHoldAltitude() {
        let m = flyingModel()
        let y0 = m.position.y
        run(m, seconds: 3)
        XCTAssertEqual(m.position.y, y0, accuracy: 0.05)
    }

    func testBoundaryIsEnforced() {
        let m = flyingModel()
        m.input.pitch = 1
        run(m, seconds: 12)
        XCTAssertLessThanOrEqual(m.homeDistance, Config.boundaryRadius + 0.001)
    }

    func testObstacleCollisionIsCounted() {
        let m = flyingModel()
        m.obstacles = [Obstacle(position: SIMD3<Float>(0, 0, -0.5), radius: 0.1, height: 2)]
        m.input.pitch = 1
        run(m, seconds: 3)
        XCTAssertGreaterThanOrEqual(m.collisions, 1)
    }
}
