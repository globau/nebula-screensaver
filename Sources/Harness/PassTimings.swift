import Foundation
import Metal

final class PassTimings {
    private let device: MTLDevice
    private let buffer: MTLCounterSampleBuffer
    private var stages: [Renderer.Stage] = []
    private var failure: String?
    private var frames = 0
    private var vertices: [Renderer.Stage: Double] = [:]
    private var fragments: [Renderer.Stage: Double] = [:]
    private var raw = "frame,pass,stage,vertex_start,vertex_end,fragment_start,fragment_end\n"
    private var cpuStart: UInt64 = 0
    private var gpuStart: UInt64 = 0
    private var cpuSpan: UInt64 = 0
    private var gpuSpan: UInt64 = 0

    init(device: MTLDevice) throws {
        guard device.supportsCounterSampling(.atStageBoundary),
              let set = device.counterSets?.first(where: { $0.name == MTLCommonCounterSet.timestamp.rawValue }),
              set.counters.contains(where: { $0.name == MTLCommonCounter.timestamp.rawValue }) else {
            throw SetupError("gpu does not support stage-boundary timestamp counters")
        }
        self.device = device
        let descriptor = MTLCounterSampleBufferDescriptor()
        descriptor.counterSet = set
        descriptor.storageMode = .shared
        descriptor.sampleCount = 4 * (3 + max(0, Tuning.bloomLevels * 2 - 1))
        buffer = try device.makeCounterSampleBuffer(descriptor: descriptor)
    }

    func beginMeasurement() {
        let times = device.sampleTimestamps()
        cpuStart = times.cpu
        gpuStart = times.gpu
    }

    func endMeasurement() {
        let times = device.sampleTimestamps()
        if times.cpu > cpuStart, times.gpu > gpuStart {
            cpuSpan = times.cpu - cpuStart
            gpuSpan = times.gpu - gpuStart
        }
    }

    func beginFrame() {
        stages.removeAll(keepingCapacity: true)
        failure = nil
    }

    func configure(_ pass: MTLRenderPassDescriptor, stage: Renderer.Stage) {
        let first = stages.count * 4
        guard first + 4 <= buffer.sampleCount, let attachment = pass.sampleBufferAttachments[0] else {
            failure = "timestamp sample buffer has insufficient capacity"
            return
        }
        attachment.sampleBuffer = buffer
        attachment.startOfVertexSampleIndex = first
        attachment.endOfVertexSampleIndex = first + 1
        attachment.startOfFragmentSampleIndex = first + 2
        attachment.endOfFragmentSampleIndex = first + 3
        stages.append(stage)
    }

    func collectFrame() throws {
        if let failure { throw SetupError(failure) }
        let count = stages.count * 4
        guard count > 0, let data = try buffer.resolveCounterRange(0..<count),
              data.count == count * MemoryLayout<MTLCounterResultTimestamp>.stride else {
            throw SetupError("gpu timestamp resolution failed")
        }
        let stamps = data.withUnsafeBytes { bytes in
            (0..<count).map {
                bytes.loadUnaligned(fromByteOffset: $0 * MemoryLayout<MTLCounterResultTimestamp>.stride,
                                    as: MTLCounterResultTimestamp.self).timestamp
            }
        }
        guard stamps.allSatisfy({ $0 != 0 && $0 != MTLCounterErrorValue }) else {
            throw SetupError("gpu returned invalid timestamp samples")
        }
        for (index, stage) in stages.enumerated() {
            let at = index * 4
            let vs = stamps[at], ve = stamps[at + 1], fs = stamps[at + 2], fe = stamps[at + 3]
            guard ve >= vs, fe >= fs else { throw SetupError("gpu timestamps are out of order") }
            vertices[stage, default: 0] += Double(ve - vs)
            fragments[stage, default: 0] += Double(fe - fs)
            raw += "\(frames),\(index),\(stage.rawValue),\(vs),\(ve),\(fs),\(fe)\n"
        }
        frames += 1
    }

    func writeResults(to directory: URL) throws -> String {
        guard frames > 0, cpuSpan > 0, gpuSpan > 0 else { throw SetupError("gpu clock calibration failed") }
        let msPerTick = Double(cpuSpan) / Double(gpuSpan) / 1e6
        let total = fragments.values.reduce(0, +)
        guard total > 0 else { throw SetupError("gpu pass timestamps have zero duration") }
        var summary = "stage-boundary gpu timestamps; diagnostic overhead included\n"
        summary += "stage spans may overlap or include waits; shares use summed fragment spans\n"
        summary += "pass                  fragment ms/frame  vertex ms/frame      share\n"
        for stage in Renderer.Stage.allCases {
            let vertex = vertices[stage, default: 0]
            let fragment = fragments[stage, default: 0]
            let label = stage.rawValue.padding(toLength: 20, withPad: " ", startingAt: 0)
            summary += String(format: "%@ %18.3f %16.3f %9.1f%%\n", label,
                              fragment * msPerTick / Double(frames), vertex * msPerTick / Double(frames),
                              fragment / total * 100)
        }
        try summary.write(to: directory.appendingPathComponent("passes.txt"), atomically: true, encoding: .utf8)
        try raw.write(to: directory.appendingPathComponent("pass-timestamps.csv"), atomically: true, encoding: .utf8)
        let clock = "cpu clock span (ns): \(cpuSpan)\ngpu clock span (ticks): \(gpuSpan)\nms per gpu tick: \(msPerTick)\n"
        try clock.write(to: directory.appendingPathComponent("timing-clock.txt"), atomically: true, encoding: .utf8)
        return summary
    }
}
