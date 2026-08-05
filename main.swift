// Scarlett Volume — volume control for Focusrite Scarlett (and any audio
// interface without software volume) from the menu bar and the volume keys.
//
// How it works: macOS sends system audio to BlackHole (virtual device); the app
// copies that stream to the Scarlett while applying a software gain, through a
// private CoreAudio aggregate. At 100%, the signal passes through intact (bit-perfect).

import Cocoa
import ApplicationServices
import CoreAudio
import AVFoundation
import Accelerate
import ServiceManagement

// MARK: - Constants

private let SCARLETT_HINT = "Scarlett"
private let BLACKHOLE_HINT = "BlackHole"
private let VIRTUAL_UID = "Scarlett Volume_UID" // UID of the custom driver (see build.sh)
private let STEP: Float = 1.0 / 16.0
private let FINE_STEP: Float = 1.0 / 64.0

private let SYSDEFINED_EVENT: UInt32 = 14 // NX_SYSDEFINED
private let KEY_SOUND_UP = 0              // NX_KEYTYPE_SOUND_UP
private let KEY_SOUND_DOWN = 1            // NX_KEYTYPE_SOUND_DOWN
private let KEY_MUTE = 7                  // NX_KEYTYPE_MUTE

extension Notification.Name {
    static let stateChanged = Notification.Name("scarlettVolume.stateChanged")
}

// MARK: - CoreAudio helpers

private func caAddr(_ sel: AudioObjectPropertySelector,
                    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

private func caString(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
    var address = caAddr(sel)
    guard AudioObjectHasProperty(id, &address) else { return nil }
    var value: CFString? = nil
    var size = UInt32(MemoryLayout<CFString?>.size)
    let err = withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
    }
    guard err == noErr, let value else { return nil }
    return value as String
}

private func caDevices() -> [AudioDeviceID] {
    var address = caAddr(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    let sys = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyDataSize(sys, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(sys, &address, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

private func caStreamCount(_ id: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Int {
    var address = caAddr(kAudioDevicePropertyStreams, scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return 0 }
    return Int(size) / MemoryLayout<AudioStreamID>.size
}

private func caUInt32(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector,
                      _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
    var address = caAddr(sel, scope)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
    return value
}

private func caSetUInt32(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector,
                         _ scope: AudioObjectPropertyScope, _ value: UInt32) {
    var address = caAddr(sel, scope)
    var v = value
    _ = AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v)
}

private func caFloat32(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector,
                       _ scope: AudioObjectPropertyScope) -> Float32? {
    var address = caAddr(sel, scope)
    guard AudioObjectHasProperty(id, &address) else { return nil }
    var value: Float32 = 0
    var size = UInt32(MemoryLayout<Float32>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
    return value
}

private func caSetFloat32(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector,
                          _ scope: AudioObjectPropertyScope, _ value: Float32) {
    var address = caAddr(sel, scope)
    var v = value
    _ = AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
}

private func caIsSettable(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector,
                          _ scope: AudioObjectPropertyScope) -> Bool {
    var address = caAddr(sel, scope)
    guard AudioObjectHasProperty(id, &address) else { return false }
    var settable = DarwinBoolean(false)
    guard AudioObjectIsPropertySettable(id, &address, &settable) == noErr else { return false }
    return settable.boolValue
}

private func caDefaultDevice(_ sel: AudioObjectPropertySelector) -> AudioDeviceID {
    var address = caAddr(sel)
    var value: AudioDeviceID = 0
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &value)
    return value
}

private func caSetDefaultDevice(_ sel: AudioObjectPropertySelector, _ id: AudioDeviceID) {
    var address = caAddr(sel)
    var value = id
    _ = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                   UInt32(MemoryLayout<AudioDeviceID>.size), &value)
}

private func caNominalRate(_ id: AudioDeviceID) -> Float64 {
    var address = caAddr(kAudioDevicePropertyNominalSampleRate)
    var value: Float64 = 0
    var size = UInt32(MemoryLayout<Float64>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return 0 }
    return value
}

private func caSetNominalRate(_ id: AudioDeviceID, _ rate: Float64) {
    var address = caAddr(kAudioDevicePropertyNominalSampleRate)
    var value = rate
    _ = AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<Float64>.size), &value)
}

private func caDeviceUID(_ id: AudioDeviceID) -> String? {
    caString(id, kAudioDevicePropertyDeviceUID)
}

private func caBuiltInOutput() -> AudioDeviceID? {
    caDevices().first { id in
        caStreamCount(id, kAudioObjectPropertyScopeOutput) > 0 &&
        caUInt32(id, kAudioDevicePropertyTransportType) == UInt32(kAudioDeviceTransportTypeBuiltIn)
    }
}

// MARK: - Real-time rendering

// In the aggregate, buffer order follows the subdevice order:
// inputs = [BlackHole..., Scarlett...], outputs = [BlackHole..., Scarlett...].
// We copy the BlackHole inputs to the Scarlett outputs with the gain applied,
// and force silence on the BlackHole output (otherwise a feedback loop occurs).
private func render(_ input: UnsafePointer<AudioBufferList>,
                    _ output: UnsafeMutablePointer<AudioBufferList>,
                    _ bhInBufs: Int, _ bhOutBufs: Int, _ gain: Float) {
    let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
    let dst = UnsafeMutableAudioBufferListPointer(output)

    for i in 0..<dst.count {
        if let d = dst[i].mData { memset(d, 0, Int(dst[i].mDataByteSize)) }
    }
    guard gain > 0, bhInBufs > 0, src.count > 0 else { return }

    var g = gain
    var si = 0
    var di = bhOutBufs
    while si < min(bhInBufs, src.count) && di < dst.count {
        let s = src[si]
        let d = dst[di]
        if let sp = s.mData?.assumingMemoryBound(to: Float.self),
           let dp = d.mData?.assumingMemoryBound(to: Float.self),
           s.mNumberChannels > 0, d.mNumberChannels > 0 {
            if s.mNumberChannels == d.mNumberChannels {
                let n = min(Int(s.mDataByteSize), Int(d.mDataByteSize)) / MemoryLayout<Float>.size
                vDSP_vsmul(sp, 1, &g, dp, 1, vDSP_Length(n))
            } else {
                let sc = Int(s.mNumberChannels), dc = Int(d.mNumberChannels)
                let frames = min(Int(s.mDataByteSize) / 4 / sc, Int(d.mDataByteSize) / 4 / dc)
                for c in 0..<min(sc, dc) {
                    vDSP_vsmul(sp + c, sc, &g, dp + c, dc, vDSP_Length(frames))
                }
            }
        }
        si += 1
        di += 1
    }
}

// MARK: - Audio engine (BlackHole → Scarlett aggregate)

final class Engine {
    static let shared = Engine()

    private(set) var running = false
    private(set) var scarlett: AudioDeviceID = 0
    private(set) var blackhole: AudioDeviceID = 0
    let gain: UnsafeMutablePointer<Float>

    // The virtual device exposes native volume/mute: macOS then handles the keys
    // and HUD itself, and the bridge stays at gain 1 (bit-perfect).
    private(set) var nativeVolume = false

    private var aggregate: AudioDeviceID = 0
    private var proc: AudioDeviceIOProcID?
    private var rateListener: AudioObjectPropertyListenerBlock?
    private var rateListenerDevice: AudioDeviceID = 0
    private var controlListener: AudioObjectPropertyListenerBlock?
    private var controlListenerDevice: AudioDeviceID = 0

    var onRateChange: (() -> Void)?
    var onControlChange: (() -> Void)? // volume/mute changed from the system

    private init() {
        gain = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        gain.initialize(to: 1)
    }

    var scarlettName: String {
        scarlett != 0 ? (caString(scarlett, kAudioObjectPropertyName) ?? "Scarlett") : "Scarlett"
    }
    var blackholeInstalled: Bool { blackhole != 0 }
    var scarlettPresent: Bool { scarlett != 0 }

    // The custom driver is present (not just an old BlackHole)
    var properVirtualInstalled: Bool {
        caDevices().contains { caDeviceUID($0) == VIRTUAL_UID }
    }

    @discardableResult
    func discover() -> Bool {
        let devices = caDevices()
        // Virtual device: ours first, otherwise a standard BlackHole
        blackhole = devices.first { caDeviceUID($0) == VIRTUAL_UID }
            ?? devices.first { id in
                guard let name = caString(id, kAudioObjectPropertyName) else { return false }
                return name.localizedCaseInsensitiveContains(BLACKHOLE_HINT) &&
                       caStreamCount(id, kAudioObjectPropertyScopeOutput) > 0
            } ?? 0
        // The physical interface: named "Scarlett" but not our virtual device
        scarlett = devices.first { id in
            guard id != blackhole, caDeviceUID(id) != VIRTUAL_UID,
                  let name = caString(id, kAudioObjectPropertyName) else { return false }
            return name.localizedCaseInsensitiveContains(SCARLETT_HINT) &&
                   caStreamCount(id, kAudioObjectPropertyScopeOutput) > 0 &&
                   caUInt32(id, kAudioDevicePropertyTransportType) != UInt32(kAudioDeviceTransportTypeVirtual)
        } ?? 0
        return blackhole != 0 && scarlett != 0
    }

    @discardableResult
    func start() -> Bool {
        guard !running else { return true }
        guard discover(),
              let bhUID = caString(blackhole, kAudioDevicePropertyDeviceUID),
              let scUID = caString(scarlett, kAudioDevicePropertyDeviceUID) else { return false }

        // Align BlackHole to the Scarlett's sample rate before aggregating
        let rate = caNominalRate(scarlett)
        if rate > 0, caNominalRate(blackhole) != rate { caSetNominalRate(blackhole, rate) }

        let desc: [String: Any] = [
            "name": "Scarlett Volume Engine",
            "uid": "com.kortexs.scarlett-volume.engine",
            "private": 1,
            "master": scUID, // clock: the Scarlett, BlackHole compensates for drift
            "subdevices": [
                ["uid": bhUID, "drift": 1],
                ["uid": scUID],
            ],
        ]
        var agg: AudioDeviceID = 0
        guard AudioHardwareCreateAggregateDevice(desc as CFDictionary, &agg) == noErr, agg != 0 else {
            return false
        }
        aggregate = agg
        if rate > 0 { caSetNominalRate(agg, rate) }

        let bhIn = caStreamCount(blackhole, kAudioObjectPropertyScopeInput)
        let bhOut = caStreamCount(blackhole, kAudioObjectPropertyScopeOutput)
        let g = gain
        var p: AudioDeviceIOProcID?
        let created = AudioDeviceCreateIOProcIDWithBlock(&p, agg, nil) { _, inData, _, outData, _ in
            render(inData, outData, bhIn, bhOut, g.pointee)
        }
        guard created == noErr, let p, AudioDeviceStart(agg, p) == noErr else {
            if let p { AudioDeviceDestroyIOProcID(agg, p) }
            AudioHardwareDestroyAggregateDevice(agg)
            aggregate = 0
            return false
        }
        proc = p
        nativeVolume = caIsSettable(blackhole, kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput)
        installRateListener()
        if nativeVolume { installControlListeners() }
        running = true
        return true
    }

    func stop() {
        removeRateListener()
        removeControlListeners()
        if aggregate != 0 {
            if let proc {
                AudioDeviceStop(aggregate, proc)
                AudioDeviceDestroyIOProcID(aggregate, proc)
            }
            AudioHardwareDestroyAggregateDevice(aggregate)
        }
        proc = nil
        aggregate = 0
        running = false
    }

    // The Scarlett changes sample rate (e.g. a 96 kHz session) → rebuild the aggregate
    private func installRateListener() {
        guard scarlett != 0 else { return }
        var address = caAddr(kAudioDevicePropertyNominalSampleRate)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.onRateChange?() }
        }
        if AudioObjectAddPropertyListenerBlock(scarlett, &address, .main, block) == noErr {
            rateListener = block
            rateListenerDevice = scarlett
        }
    }

    private func removeRateListener() {
        if let rateListener, rateListenerDevice != 0 {
            var address = caAddr(kAudioDevicePropertyNominalSampleRate)
            AudioObjectRemovePropertyListenerBlock(rateListenerDevice, &address, .main, rateListener)
        }
        rateListener = nil
        rateListenerDevice = 0
    }

    // Volume/mute adjusted from Control Center or the keys → we follow along
    private func installControlListeners() {
        guard blackhole != 0 else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.onControlChange?()
        }
        var volAddr = caAddr(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput)
        var muteAddr = caAddr(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)
        AudioObjectAddPropertyListenerBlock(blackhole, &volAddr, .main, block)
        AudioObjectAddPropertyListenerBlock(blackhole, &muteAddr, .main, block)
        controlListener = block
        controlListenerDevice = blackhole
    }

    private func removeControlListeners() {
        if let controlListener, controlListenerDevice != 0 {
            var volAddr = caAddr(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput)
            var muteAddr = caAddr(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)
            AudioObjectRemovePropertyListenerBlock(controlListenerDevice, &volAddr, .main, controlListener)
            AudioObjectRemovePropertyListenerBlock(controlListenerDevice, &muteAddr, .main, controlListener)
        }
        controlListener = nil
        controlListenerDevice = 0
    }
}

// MARK: - Volume state

final class VolumeState {
    static let shared = VolumeState()
    private let defaults = UserDefaults.standard
    private var stored: Float      // last known volume (persists across sessions)
    private var storedMuted: Bool

    private init() {
        stored = defaults.object(forKey: "volume") != nil ? defaults.float(forKey: "volume") : 0.6
        storedMuted = defaults.bool(forKey: "muted")
    }

    // In native mode, the source of truth is the virtual device itself:
    // Control Center, the keys, and our menu all drive the same control.
    private var native: Bool { Engine.shared.running && Engine.shared.nativeVolume }

    var volume: Float {
        get {
            if native, let v = caFloat32(Engine.shared.blackhole, kAudioDevicePropertyVolumeScalar,
                                         kAudioObjectPropertyScopeOutput) {
                return v
            }
            return stored
        }
        set {
            stored = min(1, max(0, newValue))
            defaults.set(stored, forKey: "volume")
            if native {
                caSetFloat32(Engine.shared.blackhole, kAudioDevicePropertyVolumeScalar,
                             kAudioObjectPropertyScopeOutput, stored)
            }
            applyGain()
        }
    }

    var muted: Bool {
        get {
            if native, let m = caUInt32(Engine.shared.blackhole, kAudioDevicePropertyMute,
                                        kAudioObjectPropertyScopeOutput) {
                return m != 0
            }
            return storedMuted
        }
        set {
            storedMuted = newValue
            defaults.set(storedMuted, forKey: "muted")
            if native {
                caSetUInt32(Engine.shared.blackhole, kAudioDevicePropertyMute,
                            kAudioObjectPropertyScopeOutput, storedMuted ? 1 : 0)
            }
            applyGain()
        }
    }

    // On engine startup: restore the persisted state onto the device
    func pushToDevice() {
        if native {
            caSetFloat32(Engine.shared.blackhole, kAudioDevicePropertyVolumeScalar,
                         kAudioObjectPropertyScopeOutput, stored)
            caSetUInt32(Engine.shared.blackhole, kAudioDevicePropertyMute,
                        kAudioObjectPropertyScopeOutput, storedMuted ? 1 : 0)
        }
        applyGain()
    }

    // Volume/mute changed from the system (Control Center, native keys)
    func syncFromDevice() {
        guard native else { return }
        if let v = caFloat32(Engine.shared.blackhole, kAudioDevicePropertyVolumeScalar,
                             kAudioObjectPropertyScopeOutput) {
            stored = v
            defaults.set(stored, forKey: "volume")
        }
        if let m = caUInt32(Engine.shared.blackhole, kAudioDevicePropertyMute,
                            kAudioObjectPropertyScopeOutput) {
            storedMuted = m != 0
            defaults.set(storedMuted, forKey: "muted")
        }
        NotificationCenter.default.post(name: .stateChanged, object: nil)
    }

    private func applyGain() {
        if native {
            // The driver applies volume and mute: transparent bridge
            Engine.shared.gain.pointee = 1
        } else {
            // Fallback mode: perceptual curve v³ (50% ≈ −18 dB), 100% = intact
            Engine.shared.gain.pointee = storedMuted ? 0 : powf(stored, 3)
        }
        NotificationCenter.default.post(name: .stateChanged, object: nil)
    }

    func bump(_ delta: Float) {
        if muted { muted = false }
        volume += delta
    }
}

// MARK: - HUD (system-style volume bubble)

private final class HUDView: NSView {
    var volume: Float = 0
    var muted = false

    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = 16
        let topLine: CGFloat = bounds.height - 26

        // Icon
        let symbol = (muted || volume == 0) ? "speaker.slash.fill"
            : volume < 0.34 ? "speaker.wave.1.fill"
            : volume < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)) {
            let tinted = img.tinted(with: .labelColor)
            tinted.draw(at: NSPoint(x: inset, y: topLine + 1),
                        from: .zero, operation: .sourceOver, fraction: 1)
        }

        // Caption
        let title = "Scarlett Volume"
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]
        (title as NSString).draw(at: NSPoint(x: inset + 26, y: topLine), withAttributes: titleAttrs)

        // Percentage
        let text = muted ? "Muted" : "\(Int((volume * 100).rounded())) %"
        let pctAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let textSize = (text as NSString).size(withAttributes: pctAttrs)
        (text as NSString).draw(at: NSPoint(x: bounds.width - inset - textSize.width, y: topLine),
                                withAttributes: pctAttrs)

        // Level bar
        let track = NSRect(x: inset, y: 16, width: bounds.width - inset * 2, height: 6)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
        let level = muted ? 0 : CGFloat(volume)
        if level > 0 {
            var fill = track
            fill.size.width = max(6, track.width * level)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: fill, xRadius: 3, yRadius: 3).fill()
        }
    }
}

final class HUD {
    private let panel: NSPanel
    private let view = HUDView(frame: NSRect(x: 0, y: 0, width: 270, height: 62))
    private var hideTimer: Timer?

    init() {
        panel = NSPanel(contentRect: view.frame,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let effect = NSVisualEffectView(frame: view.bounds)
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]
        view.autoresizingMask = [.width, .height]
        effect.addSubview(view)
        panel.contentView = effect
    }

    func show(volume: Float, muted: Bool) {
        view.volume = volume
        view.muted = muted
        view.needsDisplay = true
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.maxX - panel.frame.width - 12,
                                         y: f.maxY - panel.frame.height - 10))
        }
        hideTimer?.invalidate()
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 1.3, repeats: false) { [weak self] _ in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.35
                self.panel.animator().alphaValue = 0
            }, completionHandler: { self.panel.orderOut(nil) })
        }
    }
}

private extension NSImage {
    func tinted(with color: NSColor) -> NSImage {
        guard let copy = self.copy() as? NSImage else { return self }
        copy.lockFocus()
        color.set()
        NSRect(origin: .zero, size: copy.size).fill(using: .sourceAtop)
        copy.unlockFocus()
        copy.isTemplate = false
        return copy
    }
}

// MARK: - Volume key interception

private func mediaKeyCallback(proxy: CGEventTapProxy, type: CGEventType,
                              event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let delegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        delegate.reenableTap()
        return Unmanaged.passUnretained(event)
    }
    guard type.rawValue == SYSDEFINED_EVENT,
          let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else {
        return Unmanaged.passUnretained(event)
    }
    let data1 = ns.data1
    let keyCode = (data1 & 0xFFFF_0000) >> 16
    guard keyCode == KEY_SOUND_UP || keyCode == KEY_SOUND_DOWN || keyCode == KEY_MUTE else {
        return Unmanaged.passUnretained(event)
    }
    // If the engine isn't active (another output selected, Scarlett absent…),
    // we let macOS handle the keys normally.
    guard delegate.interceptActive else { return Unmanaged.passUnretained(event) }

    let flags = data1 & 0xFFFF
    let isDown = ((flags & 0xFF00) >> 8) == 0x0A
    if isDown {
        let fine = ns.modifierFlags.contains(.shift) && ns.modifierFlags.contains(.option)
        DispatchQueue.main.async { delegate.handleMediaKey(keyCode, fine: fine) }
    }
    return nil // consumed (down and up): no system "forbidden" bezel
}

// MARK: - Application

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var slider: NSSlider!
    private var muteItem: NSMenuItem!
    private var infoItem: NSMenuItem!
    private var installItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private let hud = HUD()
    private var installingBlackHole = false

    private var eventTap: CFMachPort?
    private(set) var interceptActive = false
    private var micAuthorized = false
    private var deviceDebounce: Timer?
    private var axTimer: Timer?
    private var activity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Scarlett audio bridge")
        Engine.shared.onRateChange = { [weak self] in self?.restartEngine() }
        Engine.shared.onControlChange = { VolumeState.shared.syncFromDevice() }
        buildStatusItem()
        NotificationCenter.default.addObserver(forName: .stateChanged, object: nil, queue: .main) { [weak self] _ in
            self?.refreshUI()
        }
        installSystemListeners()
        requestMicThenStart()
        refreshUI()

        // Virtual driver missing (or old generic BlackHole)? Offer to install it
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            if !Engine.shared.properVirtualInstalled { self.offerDriverInstall() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        let e = Engine.shared
        e.stop()
        // Return the output to the Scarlett (or the internal speakers)
        let target = e.scarlettPresent ? e.scarlett : (caBuiltInOutput() ?? 0)
        if target != 0 {
            caSetDefaultDevice(kAudioHardwarePropertyDefaultOutputDevice, target)
            caSetDefaultDevice(kAudioHardwarePropertyDefaultSystemOutputDevice, target)
        }
    }

    // MARK: Menu bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 34))
        slider = NSSlider(value: Double(VolumeState.shared.volume), minValue: 0, maxValue: 1,
                          target: self, action: #selector(sliderMoved(_:)))
        slider.frame = NSRect(x: 14, y: 6, width: 222, height: 22)
        slider.isContinuous = true
        container.addSubview(slider)
        let sliderItem = NSMenuItem()
        sliderItem.view = container
        menu.addItem(sliderItem)

        muteItem = NSMenuItem(title: "Mute", action: #selector(toggleMute), keyEquivalent: "m")
        muteItem.target = self
        menu.addItem(muteItem)

        menu.addItem(.separator())

        infoItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        menu.addItem(infoItem)

        installItem = NSMenuItem(title: "Install the virtual device…",
                                 action: #selector(installDriverAction), keyEquivalent: "")
        installItem.target = self
        menu.addItem(installItem)

        let restart = NSMenuItem(title: "Restart the audio engine",
                                 action: #selector(restartEngineAction), keyEquivalent: "r")
        restart.target = self
        menu.addItem(restart)

        menu.addItem(.separator())

        loginItem = NSMenuItem(title: "Open at login",
                               action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)

        menu.addItem(NSMenuItem(title: "Quit Scarlett Volume",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    @objc private func sliderMoved(_ sender: NSSlider) {
        if VolumeState.shared.muted { VolumeState.shared.muted = false }
        VolumeState.shared.volume = sender.floatValue
    }

    @objc private func toggleMute() {
        VolumeState.shared.muted.toggle()
    }

    @objc private func restartEngineAction() {
        restartEngine()
    }

    @objc private func installDriverAction() {
        installDriver()
    }

    // MARK: Virtual device installation

    private func offerDriverInstall() {
        let alert = NSAlert()
        alert.messageText = "Install the \"Scarlett Volume\" virtual device?"
        alert.informativeText = """
        It's what lets you control the Scarlett's volume with the keyboard \
        keys and the native macOS interface (it replaces "BlackHole 2ch" \
        if present).

        Installation asks for the administrator password, then restarts the \
        Mac's audio service (the sound cuts out for a second or two).
        """
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { installDriver() }
    }

    private func installDriver() {
        guard !installingBlackHole else { return }
        guard let driver = Bundle.main.path(forResource: "Scarlett Volume", ofType: "driver") else {
            let alert = NSAlert()
            alert.messageText = "Driver not found"
            alert.informativeText = "\"Scarlett Volume.driver\" is missing from the app's resources. "
                + "Rebuild the app with build.sh."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
        installingBlackHole = true
        infoItem.title = "Installing the virtual device…"

        // Replace the old BlackHole if present, install our driver,
        // then restart coreaudiod — with the native password prompt
        let hal = "/Library/Audio/Plug-Ins/HAL"
        let shell = "/bin/rm -rf '\(hal)/BlackHole2ch.driver' '\(hal)/Scarlett Volume.driver' && "
            + "/bin/cp -R '\(driver)' '\(hal)/' && /usr/bin/killall coreaudiod"
        let script = "do shell script \"\(shell)\" with administrator privileges"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            var ok = false
            do {
                try process.run()
                process.waitUntilExit()
                ok = process.terminationStatus == 0
            } catch {
                ok = false
            }
            DispatchQueue.main.async {
                self?.installingBlackHole = false
                if ok {
                    // coreaudiod restarts: we relaunch the engine when BlackHole appears
                    // (the device listener handles it, this is a safety belt)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.devicesChanged() }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 6) { self?.devicesChanged() }
                }
                self?.refreshUI()
            }
        }
    }

    @objc private func toggleLogin() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("SMAppService : \(error)")
        }
        refreshUI()
    }

    // MARK: Engine

    private func requestMicThenStart() {
        // Capturing the BlackHole input goes through the macOS "microphone" permission
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            micAuthorized = true
            startEngine()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] ok in
                DispatchQueue.main.async {
                    self?.micAuthorized = ok
                    if ok { self?.startEngine() } else { self?.refreshUI() }
                }
            }
        default:
            micAuthorized = false
            refreshUI()
        }
    }

    private func startEngine() {
        guard micAuthorized else { return }
        guard Engine.shared.start() else {
            updateIntercept()
            refreshUI()
            return
        }
        VolumeState.shared.pushToDevice()
        caSetDefaultDevice(kAudioHardwarePropertyDefaultOutputDevice, Engine.shared.blackhole)
        caSetDefaultDevice(kAudioHardwarePropertyDefaultSystemOutputDevice, Engine.shared.blackhole)
        // Native volume: macOS handles keys + HUD, no event tap needed.
        // Otherwise (old BlackHole without volume), we intercept the keys ourselves.
        if !Engine.shared.nativeVolume { setupTapWhenTrusted() }
        updateIntercept()
        refreshUI()
    }

    func restartEngine() {
        Engine.shared.stop()
        startEngine()
    }

    private func installSystemListeners() {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var devicesAddr = caAddr(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(sys, &devicesAddr, .main) { [weak self] _, _ in
            guard let self else { return }
            self.deviceDebounce?.invalidate()
            self.deviceDebounce = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
                self?.devicesChanged()
            }
        }
        var defaultAddr = caAddr(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(sys, &defaultAddr, .main) { [weak self] _, _ in
            self?.updateIntercept()
        }
    }

    private func devicesChanged() {
        let e = Engine.shared
        if e.running {
            let devices = caDevices()
            if !devices.contains(e.scarlett) || !devices.contains(e.blackhole) { e.stop() }
        }
        if !e.running {
            startEngine()
        }
        if !e.running && !e.scarlettPresent {
            // Scarlett unplugged: switch to the internal speakers
            if let builtIn = caBuiltInOutput() {
                caSetDefaultDevice(kAudioHardwarePropertyDefaultOutputDevice, builtIn)
                caSetDefaultDevice(kAudioHardwarePropertyDefaultSystemOutputDevice, builtIn)
            }
        }
        updateIntercept()
        refreshUI()
    }

    private func updateIntercept() {
        let e = Engine.shared
        interceptActive = e.running && !e.nativeVolume &&
            caDefaultDevice(kAudioHardwarePropertyDefaultOutputDevice) == e.blackhole
    }

    // MARK: Volume keys

    private func setupTapWhenTrusted() {
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(prompt) {
            createTap()
            return
        }
        axTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            if AXIsProcessTrusted() {
                timer.invalidate()
                self?.createTap()
            }
        }
    }

    private func createTap() {
        guard eventTap == nil else { return }
        let mask = CGEventMask(1 << 14) // NX_SYSDEFINED
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: mask,
                                          callback: mediaKeyCallback,
                                          userInfo: refcon),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return }
        eventTap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func reenableTap() {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
    }

    func handleMediaKey(_ keyCode: Int, fine: Bool) {
        let state = VolumeState.shared
        switch keyCode {
        case KEY_SOUND_UP: state.bump(fine ? FINE_STEP : STEP)
        case KEY_SOUND_DOWN: state.bump(-(fine ? FINE_STEP : STEP))
        case KEY_MUTE: state.muted.toggle()
        default: return
        }
        hud.show(volume: state.volume, muted: state.muted)
    }

    // MARK: UI

    func menuWillOpen(_ menu: NSMenu) {
        refreshUI()
    }

    private func refreshUI() {
        let s = VolumeState.shared
        let e = Engine.shared

        slider.floatValue = s.volume
        slider.isEnabled = e.running
        muteItem.state = s.muted ? .on : .off

        if installingBlackHole {
            infoItem.title = "Installing the virtual device…"
        } else if e.running {
            infoItem.title = "Output: \(e.scarlettName) — \(Int(caNominalRate(e.scarlett) / 1000)) kHz"
        } else if !micAuthorized {
            infoItem.title = "⚠️ Microphone access denied (Settings → Privacy)"
        } else {
            e.discover()
            if !e.blackholeInstalled {
                infoItem.title = "⚠️ Virtual device not installed"
            } else if !e.scarlettPresent {
                infoItem.title = "⚠️ Scarlett not detected"
            } else {
                infoItem.title = "Engine stopped"
            }
        }

        if !e.running { e.discover() }
        installItem.isHidden = e.properVirtualInstalled

        if #available(macOS 13.0, *) {
            loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }

        statusItem.button?.image = knobStatusIcon(volume: s.volume, muted: s.muted, running: e.running)
    }

    // Monochrome mini volume knob (template: macOS tints it to match the bar).
    // The needle follows the volume, the ticks turn off beyond the level.
    private func knobStatusIcon(volume: Float, muted: Bool, running: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let c = NSPoint(x: 9, y: 9)
            func dir(_ deg: CGFloat) -> NSPoint {
                let r = deg * .pi / 180
                return NSPoint(x: cos(r), y: sin(r))
            }
            func ray(_ deg: CGFloat, _ r0: CGFloat, _ r1: CGFloat, _ width: CGFloat) -> NSBezierPath {
                let d = dir(deg)
                let p = NSBezierPath()
                p.move(to: NSPoint(x: c.x + d.x * r0, y: c.y + d.y * r0))
                p.line(to: NSPoint(x: c.x + d.x * r1, y: c.y + d.y * r1))
                p.lineWidth = width
                p.lineCapStyle = .round
                return p
            }

            let ring = NSBezierPath(ovalIn: NSRect(x: c.x - 6.1, y: c.y - 6.1, width: 12.2, height: 12.2))
            ring.lineWidth = 1.5

            // Engine stopped: faded dashed ring, nothing else
            guard running else {
                ring.setLineDash([2.4, 2.2], count: 2, phase: 0)
                NSColor.black.withAlphaComponent(0.5).setStroke()
                ring.stroke()
                return true
            }

            NSColor.black.setStroke()
            ring.stroke()

            // Ticks (min bottom-left → max bottom-right, 270° sweep)
            let angles: [CGFloat] = [225, 157.5, 90, 22.5, -45]
            for (i, a) in angles.enumerated() {
                let t = Float(i) / Float(angles.count - 1)
                let on = !muted && t <= volume
                NSColor.black.withAlphaComponent(on ? 0.95 : 0.35).setStroke()
                ray(a, 7.1, 8.3, 1.4).stroke()
            }

            NSColor.black.setStroke()
            if muted {
                // Diagonal "mute" slash
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: c.x - 4.4, y: c.y + 4.4))
                slash.line(to: NSPoint(x: c.x + 4.4, y: c.y - 4.4))
                slash.lineWidth = 1.8
                slash.lineCapStyle = .round
                slash.stroke()
            } else {
                // Needle
                let a = 225 - CGFloat(max(0, min(1, volume))) * 270
                ray(a, 1.0, 4.6, 1.9).stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Scarlett Volume"
        return image
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
