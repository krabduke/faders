import CoreAudio
import Foundation

struct TapError: Error, CustomStringConvertible {
    let step: String
    let status: OSStatus
    var description: String { "\(step) failed (\(status))" }
}

/// Plays one app's sound at a chosen volume.
///
/// A Core Audio process tap (macOS 14.2+) captures the app's audio and mutes its normal
/// output. A private aggregate device made of the current output device plus that tap
/// runs an IO callback that copies the captured audio to the speakers, scaled by `volume`.
/// Destroying the tap (or quitting Faders) gives the app its normal output back.
final class AppTap {
    let processObjects: [AudioObjectID]
    let outputUID: String

    private var tapID = AudioObjectID.unknown
    private var aggregateID = AudioObjectID.unknown
    private var ioProcID: AudioDeviceIOProcID?
    private let gain = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private let peak = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private let queue = DispatchQueue(label: "com.krabduke.faders.tap", qos: .userInteractive)

    var volume: Float {
        get { gain.pointee }
        set { gain.pointee = newValue }
    }

    /// Loudest captured sample since the last call. Stays at zero when macOS hasn't given
    /// Faders permission to capture audio, because the tap then delivers silence.
    func takePeak() -> Float {
        let value = peak.pointee
        peak.pointee = 0
        return value
    }

    init(processObjects: [AudioObjectID], output: AudioObjectID, outputUID: String, volume: Float) throws {
        self.processObjects = processObjects
        self.outputUID = outputUID
        gain.initialize(to: volume)
        peak.initialize(to: 0)
        do {
            try start(output: output)
        } catch {
            stop()
            gain.deallocate()
            peak.deallocate()
            throw error
        }
    }

    deinit {
        stop()
        gain.deallocate()
        peak.deallocate()
    }

    private func start(output: AudioObjectID) throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processObjects)
        description.uuid = UUID()
        description.name = "Faders"
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true

        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw TapError(step: "Creating the tap", status: status) }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Faders",
            kAudioAggregateDeviceUIDKey: "com.krabduke.faders.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else { throw TapError(step: "Creating the output device", status: status) }

        // The aggregate's input buffers are the output device's own inputs (if it has any,
        // like a headset mic) followed by the tap. Skip the device's ones.
        let skip = output.bufferCount(scope: kAudioObjectPropertyScopeInput)
        let gain = self.gain
        let peak = self.peak

        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { _, input, _, output, _ in
            let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            let outputs = UnsafeMutableAudioBufferListPointer(output)
            let loudest = Self.render(inputs, skipping: skip, into: outputs, gain: gain.pointee)
            if loudest > peak.pointee { peak.pointee = loudest }
        }
        guard status == noErr else { throw TapError(step: "Starting playback", status: status) }

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else { throw TapError(step: "Starting playback", status: status) }
    }

    func stop() {
        if aggregateID != .unknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != .unknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        ioProcID = nil
        aggregateID = .unknown
        tapID = .unknown
    }

    /// One channel inside an interleaved or planar Float32 buffer.
    private struct Channel {
        var samples: UnsafeMutablePointer<Float>
        var offset: Int
        var stride: Int
        var frames: Int
        func sample(_ frame: Int) -> Float { samples[frame * stride + offset] }
    }

    /// Copies the tap's channels (a stereo mixdown, so at most two) to the output's first
    /// channels in order, scaled by `gain`, and silences the rest. Runs on the real-time audio
    /// thread, so it does not allocate. The HAL always hands IO procs Float32 samples.
    private static func render(_ inputs: UnsafeMutableAudioBufferListPointer, skipping skip: Int,
                               into outputs: UnsafeMutableAudioBufferListPointer, gain: Float) -> Float {
        var left: Channel?
        var right: Channel?
        var index = skip
        while index < inputs.count, right == nil {
            let buffer = inputs[index]
            index += 1
            guard let data = buffer.mData, buffer.mNumberChannels > 0 else { continue }
            let stride = Int(buffer.mNumberChannels)
            let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * stride)
            let samples = data.assumingMemoryBound(to: Float.self)
            for offset in 0..<min(stride, 2) {
                let channel = Channel(samples: samples, offset: offset, stride: stride, frames: frames)
                if left == nil { left = channel } else if right == nil { right = channel }
            }
        }
        // A mono tap feeds both speakers.
        if right == nil { right = left }

        var loudest: Float = 0
        var outChannel = 0
        for buffer in outputs {
            guard let data = buffer.mData, buffer.mNumberChannels > 0 else { continue }
            let stride = Int(buffer.mNumberChannels)
            let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * stride)
            let samples = data.assumingMemoryBound(to: Float.self)
            for offset in 0..<stride {
                let source = outChannel == 0 ? left : (outChannel == 1 ? right : nil)
                let count = source.map { min(frames, $0.frames) } ?? 0
                if let source {
                    for frame in 0..<count {
                        let sample = source.sample(frame)
                        loudest = max(loudest, abs(sample))
                        samples[frame * stride + offset] = sample * gain
                    }
                }
                for frame in count..<frames { samples[frame * stride + offset] = 0 }
                outChannel += 1
            }
        }
        return loudest
    }
}
