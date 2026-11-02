import AppKit
import AudioToolbox
import CoreAudio
import Combine

/// One app as the user sees it. Browsers and games often play sound from helper processes,
/// so an app can own several Core Audio process objects.
struct AudioApp: Identifiable, Equatable {
    let id: String            // bundle ID, or "pid:<n>" when there is none
    var name: String
    var icon: NSImage
    var tint: NSColor
    var processObjects: [AudioObjectID]
    var isPlaying: Bool

    static func == (a: AudioApp, b: AudioApp) -> Bool {
        a.id == b.id && a.name == b.name && a.processObjects == b.processObjects && a.isPlaying == b.isPlaying
    }
}

final class Mixer: ObservableObject {
    @Published private(set) var apps: [AudioApp] = []
    @Published private(set) var outputName = ""
    @Published private(set) var mainVolume: Float?
    @Published private(set) var problem: String?

    /// Saved per app, by `AudioApp.id`. Missing means 100%.
    @Published private var volumes: [String: Float] = UserDefaults.standard.dictionary(forKey: "volumes") as? [String: Float] ?? [:]
    @Published private var muted: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "muted") ?? [])

    private var taps: [String: AppTap] = [:]
    private var listeners: [PropertyListener] = []
    private var mainVolumeListener: PropertyListener?
    private var output = AudioObjectID.unknown
    private var outputUID = ""
    private var tints: [String: NSColor] = [:]
    private var timer: Timer?
    /// Consecutive one-second checks in which a playing, tapped app delivered only silence.
    private var silentChecks: [String: Int] = [:]

    init() {
        listeners = [
            PropertyListener(.system, kAudioHardwarePropertyProcessObjectList) { [weak self] in self?.refresh() },
            PropertyListener(.system, kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in self?.outputChanged() },
        ]
        outputChanged()
    }

    // MARK: Reading and changing volumes

    func volume(of app: AudioApp) -> Float { volumes[app.id] ?? 1 }
    func isMuted(_ app: AudioApp) -> Bool { muted.contains(app.id) }
    var hasChanges: Bool { !volumes.isEmpty || !muted.isEmpty }

    func setVolume(_ value: Float, for app: AudioApp) {
        let value = min(max(value, 0), 1)
        volumes[app.id] = value >= 0.995 ? nil : value
        save()
        apply(to: app)
    }

    func toggleMute(_ app: AudioApp) {
        if muted.contains(app.id) { muted.remove(app.id) } else { muted.insert(app.id) }
        save()
        apply(to: app)
    }

    func resetAll() {
        volumes = [:]
        muted = []
        save()
        taps.values.forEach { $0.stop() }
        taps = [:]
        problem = nil
    }

    func setMainVolume(_ value: Float) {
        guard output != .unknown else { return }
        output.set(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput, Float32(value))
        mainVolume = value
    }

    private func save() {
        UserDefaults.standard.set(volumes, forKey: "volumes")
        UserDefaults.standard.set(Array(muted), forKey: "muted")
    }

    // MARK: Live updates while the popover is open

    /// "Is it playing" isn't something Core Audio notifies about, so poll it while visible.
    func setVisible(_ visible: Bool) {
        timer?.invalidate()
        timer = nil
        guard visible else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    // MARK: Output device

    private func outputChanged() {
        output = AudioObjectID.system.get(kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID.unknown) ?? .unknown
        outputUID = output.string(kAudioDevicePropertyDeviceUID) ?? ""
        outputName = output.string(kAudioObjectPropertyName) ?? "No output"
        readMainVolume()
        mainVolumeListener = output == .unknown ? nil :
            PropertyListener(output, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput) { [weak self] in
                self?.readMainVolume()
            }
        // Taps play through a specific device, so rebuild them all on the new one.
        taps.values.forEach { $0.stop() }
        taps = [:]
        refresh()
    }

    private func readMainVolume() {
        mainVolume = output.get(kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                scope: kAudioObjectPropertyScopeOutput, initial: Float32(0))
    }

    // MARK: Finding apps

    func refresh() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var byApp: [String: AudioApp] = [:]

        for object in AudioObjectID.system.objectList(kAudioHardwarePropertyProcessObjectList) {
            guard let pid = object.get(kAudioProcessPropertyPID, initial: pid_t(0)), pid > 0, pid != ownPID else { continue }
            let playing = (object.get(kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)) ?? 0) != 0
            guard let owner = Self.owningApp(pid: pid, bundleID: object.string(kAudioProcessPropertyBundleID)) else { continue }

            if var existing = byApp[owner.id] {
                existing.processObjects.append(object)
                existing.isPlaying = existing.isPlaying || playing
                byApp[owner.id] = existing
            } else {
                byApp[owner.id] = AudioApp(id: owner.id, name: owner.name, icon: owner.icon, tint: tint(for: owner),
                                           processObjects: [object], isPlaying: playing)
            }
        }

        // Show what's making sound, plus anything with a custom setting so it can be undone.
        let visible = byApp.values
            .filter { $0.isPlaying || volumes[$0.id] != nil || muted.contains($0.id) || taps[$0.id] != nil }
            .map { app -> AudioApp in var app = app; app.processObjects.sort(); return app }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if visible != apps { apps = visible }

        for app in byApp.values { apply(to: app) }
        checkPermission(visible)
        for id in taps.keys where byApp[id] == nil {
            taps[id]?.stop()
            taps[id] = nil
        }
    }

    /// Creates, updates or removes the tap for one app so it plays at its saved volume.
    /// Apps left at 100% and unmuted are never touched.
    private func apply(to app: AudioApp) {
        let gain: Float = muted.contains(app.id) ? 0 : (volumes[app.id] ?? 1)
        let objects = app.processObjects.sorted()

        guard gain < 0.995, !outputUID.isEmpty else {
            taps[app.id]?.stop()
            taps[app.id] = nil
            return
        }
        if let tap = taps[app.id], tap.processObjects == objects, tap.outputUID == outputUID {
            tap.volume = gain
            return
        }
        taps[app.id]?.stop()
        taps[app.id] = nil
        do {
            taps[app.id] = try AppTap(processObjects: objects, output: output, outputUID: outputUID, volume: gain)
            if problem != nil { problem = nil }
        } catch {
            NSLog("Faders: \(app.name): \(error)")
            problem = "Couldn't change \(app.name)'s volume. Check that Faders is allowed under System Settings → Privacy & Security → Screen & System Audio Recording."
        }
    }

    /// macOS gives a tap silence, not an error, when audio capture isn't allowed. Notice that
    /// (an app is playing, but nothing arrives for a few seconds) and say how to fix it.
    private func checkPermission(_ apps: [AudioApp]) {
        guard timer != nil else { return }
        for app in apps {
            guard let tap = taps[app.id] else { silentChecks[app.id] = nil; continue }
            let peak = tap.takePeak()
            if peak > 0, silentChecks[app.id] == nil { NSLog("Faders: receiving \(app.name)'s audio (peak \(peak))") }
            if app.isPlaying && peak == 0 {
                silentChecks[app.id, default: 0] += 1
            } else {
                silentChecks[app.id] = 0
            }
        }
        if let silent = apps.first(where: { (silentChecks[$0.id] ?? 0) >= 3 }) {
            problem = "Faders isn't receiving \(silent.name)'s sound. Allow Faders in System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen it."
        } else if problem?.hasPrefix("Faders isn't receiving") == true {
            problem = nil
        }
    }

    // MARK: Who owns a process

    private struct Owner {
        let id: String
        let name: String
        let icon: NSImage
    }

    /// Maps a helper process (a browser tab, a game's audio engine) to the app the user knows.
    private static func owningApp(pid: pid_t, bundleID: String?) -> Owner? {
        var candidates = [pid]
        if let responsible = responsiblePID(pid), responsible != pid { candidates.insert(responsible, at: 0) }

        for candidate in candidates {
            if let app = NSRunningApplication(processIdentifier: candidate), let owner = owner(of: app) {
                return owner
            }
        }
        // Helpers like "com.brave.Browser.helper": find the running app whose ID is a prefix.
        if let bundleID, !bundleID.isEmpty {
            let parent = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .first { app in app.bundleIdentifier.map { bundleID.hasPrefix($0 + ".") } ?? false }
            if let parent, let owner = owner(of: parent) { return owner }
        }
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        let name = app.localizedName ?? bundleID ?? "PID \(pid)"
        return Owner(id: app.bundleIdentifier ?? bundleID ?? "pid:\(pid)", name: name,
                     icon: app.icon ?? NSWorkspace.shared.icon(for: .applicationBundle))
    }

    private static func owner(of app: NSRunningApplication) -> Owner? {
        guard app.activationPolicy != .prohibited || app.bundleIdentifier?.hasPrefix("com.apple.") == false,
              let id = app.bundleIdentifier else { return nil }
        return Owner(id: id, name: app.localizedName ?? id, icon: app.icon ?? NSWorkspace.shared.icon(for: .applicationBundle))
    }

    /// The process macOS holds responsible for `pid` (the app that launched a helper).
    /// Private libsystem function, looked up at runtime so a missing symbol just disables it.
    private static let responsibilityFunction: (@convention(c) (pid_t) -> pid_t)? = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let symbol = dlsym(handle, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (pid_t) -> pid_t).self)
    }()

    private static func responsiblePID(_ pid: pid_t) -> pid_t? {
        guard let function = responsibilityFunction else { return nil }
        let result = function(pid)
        return result > 0 ? result : nil
    }

    private func tint(for owner: Owner) -> NSColor {
        if let cached = tints[owner.id] { return cached }
        let color = owner.icon.dominantColor
        tints[owner.id] = color
        return color
    }
}
