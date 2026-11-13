import simd

// an endless centripetal catmull-rom spline through randomly swerving waypoints; positions are
// unwrapped world coordinates
struct FlightPath {
    private struct Segment {
        let controls: [SIMD3<Double>]
        let knots: SIMD4<Double>
        let arc: [Double] // cumulative length at evenly spaced parameters

        init(_ controls: [SIMD3<Double>]) {
            self.controls = controls
            var k = SIMD4<Double>(0, 0, 0, 0)
            for i in 1..<4 {
                k[i] = k[i - 1] + max(simd_distance(controls[i - 1], controls[i]).squareRoot(), 1e-3)
            }
            knots = k
            var arc = [0.0]
            var previous = controls[1]
            for i in 1...Self.samples {
                let p = Self.evaluate(controls, k, Double(i) / Double(Self.samples))
                arc.append(arc[i - 1] + simd_distance(previous, p))
                previous = p
            }
            self.arc = arc
        }

        static let samples = 64

        var length: Double { arc[Self.samples] }

        func point(atLength s: Double) -> SIMD3<Double> {
            var lo = 0, hi = Self.samples
            while hi - lo > 1 {
                let mid = (lo + hi) / 2
                if arc[mid] <= s { lo = mid } else { hi = mid }
            }
            let span = max(arc[hi] - arc[lo], 1e-9)
            let u = (Double(lo) + min(max((s - arc[lo]) / span, 0), 1)) / Double(Self.samples)
            return Self.evaluate(controls, knots, u)
        }

        // barry and goldman's pyramidal formulation
        private static func evaluate(_ p: [SIMD3<Double>], _ k: SIMD4<Double>, _ u: Double) -> SIMD3<Double> {
            func lerp(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ ta: Double, _ tb: Double, _ t: Double) -> SIMD3<Double> {
                a * ((tb - t) / (tb - ta)) + b * ((t - ta) / (tb - ta))
            }
            let t = k[1] + (k[2] - k[1]) * u
            let a1 = lerp(p[0], p[1], k[0], k[1], t)
            let a2 = lerp(p[1], p[2], k[1], k[2], t)
            let a3 = lerp(p[2], p[3], k[2], k[3], t)
            let b1 = lerp(a1, a2, k[0], k[2], t)
            let b2 = lerp(a2, a3, k[1], k[3], t)
            return lerp(b1, b2, k[1], k[2], t)
        }
    }

    private var rng: SplitMix64
    private var points: [SIMD3<Double>]
    private var segments: [Segment] = []
    private var distance: Double = 0

    // the first `straight` units run dead ahead; four collinear waypoints keep the first segment
    // exactly straight, and swerving only begins in the segment after
    init(start: SIMD3<Double>, heading: SIMD3<Double>, straight: Double, seed: UInt64) {
        rng = SplitMix64(seed: seed)
        let h = simd_normalize(heading)
        points = [start - h * 200, start, start + h * straight, start + h * (straight + 120)]
        fill()
    }

    mutating func advance(by d: Double) {
        distance += d
        while distance >= segments[0].length {
            distance -= segments[0].length
            segments.removeFirst()
            points.removeFirst()
            fill()
        }
    }

    func point(ahead offset: Double) -> SIMD3<Double> {
        var s = distance + offset
        var i = 0
        while i < segments.count - 1 && s > segments[i].length {
            s -= segments[i].length
            i += 1
        }
        return segments[i].point(atLength: s)
    }

    private mutating func fill() {
        while segments.count < 3 {
            while points.count < segments.count + 4 { appendWaypoint() }
            segments.append(Segment(Array(points[segments.count..<segments.count + 4])))
        }
    }

    private mutating func appendWaypoint() {
        let last = points[points.count - 1]
        let heading = simd_normalize(last - points[points.count - 2])
        let swerve = rng.unitVector() * (0.3 + 0.5 * rng.unit())
        points.append(last + simd_normalize(heading + swerve) * (120 + 160 * rng.unit()))
    }
}
