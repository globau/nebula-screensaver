import simd

struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }

    mutating func unit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }

    mutating func unitVector() -> SIMD3<Double> {
        while true {
            let v = SIMD3(unit(), unit(), unit()) * 2 - 1
            let l = simd_length(v)
            if l > 0.05 && l <= 1 { return v / l }
        }
    }
}
