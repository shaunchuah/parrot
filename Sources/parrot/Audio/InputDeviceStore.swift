import CoreAudio
import Foundation

/// Which microphone parrot records from: chosen in the menu bar, remembered
/// across restarts, resolved fresh for every recording.
///
/// Devices are remembered by UID rather than AudioDeviceID, because the numeric
/// id is reassigned across reboots and reconnects — a stored id can silently
/// point at a different microphone.
///
/// Continuity / CS Microphone / iPhone mics are hidden from the picker and
/// never auto-selected: macOS often promotes them to the system default, which
/// is what this store exists to ignore. Blue Yeti / Yeti Nano, when present,
/// are pinned automatically on first launch so Continuity cannot steal the
/// next recording.
final class InputDeviceStore {
    struct Device {
        let id: AudioDeviceID
        let uid: String
        let name: String
    }

    /// FourCCs from AudioHardwareBase.h (macOS 13+). Declared as literals so
    /// we compile against the macOS 14 SDK even if the Swift overlay omits them.
    private static let continuityWired: UInt32 = 0x6363_7764    // 'ccwd'
    private static let continuityWireless: UInt32 = 0x6363_776C // 'ccwl'

    private static let systemSentinel = "__system__"

    private struct Stored: Codable {
        var uid: String?
        var name: String?
        var followSystem: Bool
    }

    private let fileURL: URL
    private var stored: Stored

    init(fileURL: URL? = nil) {
        let url = fileURL ?? Self.defaultFileURL
        self.fileURL = url
        if let loaded = Self.load(from: url) {
            self.stored = loaded
        } else if let migrated = Self.migrateFromUserDefaults() {
            self.stored = migrated
            Self.write(migrated, to: url)
        } else {
            self.stored = Stored(uid: nil, name: nil, followSystem: false)
        }
    }

    /// UID the user pinned, or nil when following the system default.
    /// Setting nil writes an explicit "Same as System" choice so a later Yeti
    /// appearance does not override it.
    var selectedUID: String? {
        get {
            if stored.followSystem { return nil }
            return stored.uid
        }
        set {
            if let newValue {
                stored.followSystem = false
                stored.uid = newValue
                stored.name = available().first { $0.uid == newValue }?.name ?? stored.name
            } else {
                stored.followSystem = true
                stored.uid = nil
                stored.name = nil
            }
            persist()
        }
    }

    /// True when the menu should check "Same as System".
    var followsSystem: Bool { stored.followSystem }

    /// Saved name of a pinned device, used when it is currently unplugged.
    var pinnedName: String? {
        stored.followSystem ? nil : stored.name
    }

    /// True when no choice has been saved yet (as opposed to an explicit
    /// "Same as System"). First launch uses this to auto-pin a Yeti.
    var hasSavedChoice: Bool {
        stored.followSystem || stored.uid != nil
    }

    /// Devices shown in the picker: real input devices, Yeti first, Continuity
    /// and CoreAudio's private aggregate hidden.
    func available() -> [Device] {
        let listed = allInputs().filter { !Self.isContinuityMicrophone($0) }
        return listed.enumerated().sorted { a, b in
            let ra = Self.preferredRank(a.element)
            let rb = Self.preferredRank(b.element)
            if ra != rb { return ra < rb }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// Device to record from now. Always prefers a concrete, non-Continuity
    /// device when one exists — returning nil would let AUHAL follow the
    /// system default, which is often Continuity.
    func resolved() -> Device? {
        let listed = available()
        if stored.followSystem {
            return usableSystemDefault(from: listed) ?? listed.first
        }
        if let uid = stored.uid, let pinned = listed.first(where: { $0.uid == uid }) {
            return pinned
        }
        // Unset, or the pinned mic is unplugged.
        if let preferred = listed.first(where: { Self.preferredRank($0) < 2 }) {
            if stored.uid == nil && !stored.followSystem {
                stored.uid = preferred.uid
                stored.name = preferred.name
                persist()
                FileHandle.standardError.write(Data(
                    "input: auto-selected \(preferred.name)\n".utf8
                ))
            }
            return preferred
        }
        if let system = usableSystemDefault(from: listed) {
            return system
        }
        return listed.first
    }

    // MARK: - Continuity / Yeti

    /// Continuity Camera / iPhone / iPad / "CS Microphone" — never listed, never
    /// auto-selected. Matches Apple's Continuity Capture transport types plus
    /// the names and UIDs those devices actually show up as.
    static func isContinuityMicrophone(_ device: Device) -> Bool {
        isContinuityMicrophone(name: device.name, uid: device.uid, transport: Self.transport(of: device.id))
    }

    static func isContinuityMicrophone(name: String, uid: String, transport: UInt32) -> Bool {
        if transport == continuityWired || transport == continuityWireless {
            return true
        }
        let haystack = "\(name) \(uid)".lowercased()
        let needles = [
            "cs microphone",
            "continuity",
            "iphone",
            "ipad",
        ]
        return needles.contains { haystack.contains($0) }
    }

    /// 0 = Yeti Nano, 1 = other Yeti, 2 = everything else.
    static func preferredRank(_ device: Device) -> Int {
        preferredRank(name: device.name, uid: device.uid)
    }

    static func preferredRank(name: String, uid: String) -> Int {
        let haystack = "\(name) \(uid)".lowercased()
        if haystack.contains("yeti nano") { return 0 }
        if haystack.contains("yeti") { return 1 }
        return 2
    }

    // MARK: - CoreAudio reads

    private func allInputs() -> [Device] {
        deviceIDs().compactMap { id in
            guard inputChannels(id) > 0, !isPrivateAggregate(id), let uid = uid(of: id) else { return nil }
            return Device(id: id, uid: uid, name: name(of: id) ?? uid)
        }
    }

    private func usableSystemDefault(from listed: [Device]) -> Device? {
        let id = Self.systemDefaultInput()
        guard id != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return listed.first { $0.id == id }
    }

    private static func systemDefaultInput() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &device
        )
        return device
    }

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

    /// Aggregate devices CoreAudio builds for its own clients are flagged private
    /// in their composition. They report input channels and are not hidden, so
    /// this is the only thing separating them from a real microphone. Aggregates
    /// the user built in Audio MIDI Setup are not private and stay listed.
    private func isPrivateAggregate(_ id: AudioDeviceID) -> Bool {
        guard Self.transport(of: id) == kAudioDeviceTransportTypeAggregate else { return false }

        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyComposition,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFDictionary>?
        var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return false }
        let composition = value.takeRetainedValue() as? [String: Any]
        return composition?[kAudioAggregateDeviceIsPrivateKey] as? Int == 1
    }

    private func uid(of id: AudioDeviceID) -> String? {
        string(id, kAudioDevicePropertyDeviceUID)
    }

    private func name(of id: AudioDeviceID) -> String? {
        string(id, kAudioObjectPropertyName)
    }

    private static func transport(of id: AudioDeviceID) -> UInt32 {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &transport) == noErr else { return 0 }
        return transport
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

    // MARK: - Persistence

    static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/parrot", isDirectory: true)
            .appendingPathComponent("input-device.json")
    }

    private func persist() {
        Self.write(stored, to: fileURL)
    }

    private static func load(from url: URL) -> Stored? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Stored.self, from: data)
    }

    private static func write(_ stored: Stored, to url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(stored)
            try data.write(to: url, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("couldn't persist input device: \(error)\n".utf8))
        }
    }

    /// The andredezzy picker stored the UID in UserDefaults. Read it once if
    /// our file is not there yet so a relaunch does not forget the choice.
    private static func migrateFromUserDefaults() -> Stored? {
        let key = "inputDeviceUID"
        let uid =
            UserDefaults(suiteName: "com.digimata.parrot")?.string(forKey: key)
            ?? UserDefaults.standard.string(forKey: key)
        guard let uid else { return nil }
        if uid == systemSentinel {
            return Stored(uid: nil, name: nil, followSystem: true)
        }
        return Stored(uid: uid, name: nil, followSystem: false)
    }
}
