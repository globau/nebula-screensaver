import simd

struct CameraBasis {
    let right: SIMD3<Double>
    let up: SIMD3<Double>
    let forward: SIMD3<Double>
}

// follows the flight path at constant speed, banking into turns; there is no world up, so the
// up vector is carried along by parallel transport
struct Camera {
    private(set) var time: Double = 0
    private(set) var worldPosition = SIMD3<Double>(repeating: 0)
    private(set) var basis = CameraBasis(right: SIMD3(1, 0, 0), up: SIMD3(0, 1, 0), forward: SIMD3(0, 0, 1))

    private var path: FlightPath
    private var transportedUp = SIMD3<Double>(0, 1, 0)
    private var roll: Double = 0
    private static let bankLookAhead: Double = 70

    // the world wraps, so any start is valid; the seed picks where the flight begins and its route
    init(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        let start = SIMD3(rng.unit(), rng.unit(), rng.unit()) * Tuning.worldPeriod
        let heading = rng.unitVector()
        // no turns, and so no banking, until the intro boost is over and the bank look-ahead has
        // passed it; the boost's extra distance is the integral of its smoothstep falloff
        let introDistance = Tuning.speed * Tuning.introDuration * (1 + Tuning.introBoost / 2)
        path = FlightPath(start: start, heading: heading, straight: introDistance + Self.bankLookAhead,
                          seed: rng.next())
        let helper = abs(heading.y) < 0.9 ? SIMD3<Double>(0, 1, 0) : SIMD3<Double>(1, 0, 0)
        transportedUp = simd_normalize(helper - heading * simd_dot(helper, heading))
        update(dt: 0)
    }

    // wrapped into the first world period, as the shaders expect
    var position: SIMD3<Double> {
        worldPosition - Tuning.worldPeriod * (worldPosition / Tuning.worldPeriod).rounded(.down)
    }

    mutating func advance(by dt: Double) {
        path.advance(by: Self.speed(at: time + dt / 2) * dt)
        time += dt
        update(dt: dt)
    }

    private static func speed(at time: Double) -> Double {
        let x = min(max(time / Tuning.introDuration, 0), 1)
        return Tuning.speed * (1 + Tuning.introBoost * (1 - x * x * (3 - 2 * x)))
    }

    private mutating func update(dt: Double) {
        let here = path.point(ahead: 0)
        let forward = simd_normalize(path.point(ahead: 30) - here)

        transportedUp = simd_normalize(transportedUp - forward * simd_dot(transportedUp, forward))
        let right = simd_normalize(simd_cross(transportedUp, forward))
        let up = simd_cross(forward, right)

        let turn = simd_normalize(path.point(ahead: Self.bankLookAhead) - path.point(ahead: 30)) - forward
        let bank = min(max(-simd_dot(turn, right) * 1.5, -0.5), 0.5)
        roll = dt > 0 ? roll + (bank - roll) * (1 - exp(-dt / 1.5)) : bank
        let rolledRight = right * cos(roll) + up * sin(roll)

        basis = CameraBasis(right: rolledRight, up: simd_cross(forward, rolledRight), forward: forward)
        worldPosition = here
    }
}
