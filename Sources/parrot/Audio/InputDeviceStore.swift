import CoreAudio
import Foundation

/// Which microphone parrot records from: chosen in the menu bar, remembered
/// across restarts, resolved fresh for every recording.
///
/// Devices are remembered by UID rather than AudioDeviceID, because the numeric
/// id is reassigned across reboots and reconnects — a stored id can silently
/// point at a different microphone.
final class InputDeviceStore {
    struct Device {
        let id: AudioDeviceID
        let uid: String
        let name: String
    }

    private static let selectionKey = "inputDeviceUID"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// UID the user picked, or nil to follow the system default input.
    var selectedUID: String? {
        get { defaults.string(forKey: Self.selectionKey) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Self.selectionKey)
            } else {
                defaults.removeObject(forKey: Self.selectionKey)
            }
        }
    }

    /// Every device that can record, in the order CoreAudio reports them.
    func available() -> [Device] {
        deviceIDs().compactMap { id in
            guard inputChannels(id) > 0, let uid = uid(of: id) else { return nil }
            return Device(id: id, uid: uid, name: name(of: id) ?? uid)
        }
    }

    /// Device to record from now. nil means follow the system default, which is
    /// also what happens when the remembered device is currently unplugged.
    func resolved() -> Device? {
        guard let selectedUID else { return nil }
        return available().first { $0.uid == selectedUID }
    }

    // MARK: - CoreAudio reads

    private func deviceIDs() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private func inputChannels(_ id: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = raw.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private func uid(of id: AudioDeviceID) -> String? {
        string(id, kAudioDevicePropertyDeviceUID)
    }

    private func name(of id: AudioDeviceID) -> String? {
        string(id, kAudioObjectPropertyName)
    }

    private func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
