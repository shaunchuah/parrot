import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

/// Captures microphone audio while recording is active and returns a 16 kHz
/// mono Float32 buffer when stopped.
///
/// Built on a standalone AUHAL unit rather than `AVAudioEngine` because only
/// AUHAL honours a device choice: `AVAudioEngine`'s input node binds to whatever
/// input is current the moment the node is first touched, and setting the device
/// afterwards — via `auAudioUnit.setDeviceID`, via `AudioUnitSetProperty`, or
/// with an `engine.reset()` in between — returns `noErr` and then delivers
/// silence. Measured on a Bluetooth headset: 0 frames in 3 s for all three,
/// against 48 000 frames for the same device through AUHAL.
///
/// AUHAL also converts to the target format itself, so there is no
/// `AVAudioConverter` in the path, and no `installTap(onBus:format:)` — which
/// removes the format-mismatch exception that could terminate the daemon when
/// the input device changed.
final class AudioCapture {
    enum CaptureError: Error {
        case unavailable
        case configurationFailed(OSStatus)
        case startFailed(OSStatus)
    }

    static let targetSampleRate: Double = 16_000

    /// Matches the old tap size; also the render buffer we preallocate, so the
    /// audio thread never allocates.
    private static let framesPerSlice: UInt32 = 4096

    private var unit: AudioUnit?
    private var buffer: AVAudioPCMBuffer?
    private var samples: [Float] = []
    private var isRecording = false
    private let lock = NSLock()

    /// Called for every audio buffer with the buffer's RMS level (0…~1).
    /// Invoked on the audio thread; hop to main if you touch UI.
    var onLevel: ((Float) -> Void)?

    /// Begin recording. Idempotent — calling while already recording is a no-op.
    /// `device` nil records from the system default input.
    func start(device: AudioDeviceID? = nil) throws {
        guard !isRecording else { return }

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw CaptureError.unavailable
        }
        var unit: AudioUnit?
        try check(AudioComponentInstanceNew(component, &unit))
        guard let unit else { throw CaptureError.unavailable }
        self.unit = unit

        var enable: UInt32 = 1
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                       kAudioUnitScope_Input, 1,
                                       &enable, UInt32(MemoryLayout<UInt32>.size)))
        var disable: UInt32 = 0
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                       kAudioUnitScope_Output, 0,
                                       &disable, UInt32(MemoryLayout<UInt32>.size)))

        // Left unset, AUHAL follows the system default input.
        if var device {
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                           kAudioUnitScope_Global, 0,
                                           &device, UInt32(MemoryLayout<AudioDeviceID>.size)))
        }

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Self.targetSampleRate,
                                         channels: 1, interleaved: false) else {
            throw CaptureError.unavailable
        }
        var asbd = format.streamDescription.pointee
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Output, 1,
                                       &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))

        var slice = Self.framesPerSlice
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice,
                                       kAudioUnitScope_Global, 0,
                                       &slice, UInt32(MemoryLayout<UInt32>.size)))
        buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.framesPerSlice)

        var callback = AURenderCallbackStruct(
            inputProc: captureRenderCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback,
                                       kAudioUnitScope_Global, 0,
                                       &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))

        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lock.unlock()

        try check(AudioUnitInitialize(unit))
        let status = AudioOutputUnitStart(unit)
        guard status == noErr else {
            dispose()
            throw CaptureError.startFailed(status)
        }
        isRecording = true
    }

    /// Stop recording and return all captured samples (16 kHz mono Float32).
    @discardableResult
    func stop() -> [Float] {
        guard isRecording else { return [] }
        isRecording = false
        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
        }
        // Dispose so the device is released; a Bluetooth headset keeps its
        // microphone link open otherwise.
        dispose()

        lock.lock()
        let captured = samples
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
        return captured
    }

    fileprivate func render(
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        bus: UInt32,
        frames: UInt32
    ) -> OSStatus {
        guard let unit, let buffer, frames <= buffer.frameCapacity else { return noErr }
        buffer.frameLength = frames
        let status = AudioUnitRender(unit, flags, timestamp, bus, frames, buffer.mutableAudioBufferList)
        guard status == noErr, let channel = buffer.floatChannelData?[0] else { return status }

        let chunk = Array(UnsafeBufferPointer(start: channel, count: Int(frames)))
        lock.lock()
        samples.append(contentsOf: chunk)
        lock.unlock()

        if let onLevel {
            onLevel(computeRMS(chunk))
        }
        return noErr
    }

    private func dispose() {
        if let unit { AudioComponentInstanceDispose(unit) }
        unit = nil
        buffer = nil
    }

    private func check(_ status: OSStatus) throws {
        guard status != noErr else { return }
        dispose()
        throw CaptureError.configurationFailed(status)
    }
}

/// C callbacks carry no context, so the instance travels through
/// `inputProcRefCon`. Unretained: the unit never outlives its AudioCapture.
private let captureRenderCallback: AURenderCallback = { refCon, flags, timestamp, bus, frames, _ in
    let capture = Unmanaged<AudioCapture>.fromOpaque(refCon).takeUnretainedValue()
    return capture.render(flags: flags, timestamp: timestamp, bus: bus, frames: frames)
}

// MARK: - WAV writer (for debugging M3 captures)

enum WAVWriter {
    /// Write Float32 mono samples as 16-bit PCM WAV to `path`.
    static func write(samples: [Float], sampleRate: Int, to path: String) throws {
        var data = Data()
        let byteCount = samples.count * 2
        data.append("RIFF".data(using: .ascii)!)
        data.append(uint32LE(UInt32(36 + byteCount)))
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        data.append(uint32LE(16))
        data.append(uint16LE(1))
        data.append(uint16LE(1))
        data.append(uint32LE(UInt32(sampleRate)))
        data.append(uint32LE(UInt32(sampleRate * 2)))
        data.append(uint16LE(2))
        data.append(uint16LE(16))
        data.append("data".data(using: .ascii)!)
        data.append(uint32LE(UInt32(byteCount)))
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            data.append(uint16LE(UInt16(bitPattern: Int16(clamped * 32767))))
        }
        try data.write(to: URL(fileURLWithPath: path))
    }

    private static func uint32LE(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)])
    }

    private static func uint16LE(_ v: UInt16) -> Data {
        Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff)])
    }
}

func computeRMS(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0 }
    let sum = samples.reduce(Float(0)) { $0 + $1 * $1 }
    return (sum / Float(samples.count)).squareRoot()
}
