import AudioToolbox
import CoreAudio
import NotchCore
import os

/// Publishes `OutputVolumeChanged` when the volume or mute state of the
/// default output device changes. Needs no permission: Core Audio property
/// listeners are open to any app (measured in the pd-1 check).
///
/// It hears every change, not only the volume keys: the menu bar slider and
/// other apps change the same property. A device with no software volume
/// (some HDMI and USB outputs) reports nothing; the keys do nothing there either.
@MainActor
public final class OutputVolumeWatcher {
    private let runtime: NotchRuntime
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var filter = VolumeChangeFilter()
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var valueListener: AudioObjectPropertyListenerBlock?
    private let log = Logger(subsystem: "dev.topnotch.TopNotch", category: "volume")

    private static var defaultDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private static var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    private static var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    public init(runtime: NotchRuntime) {
        self.runtime = runtime
    }

    var isRunning: Bool { deviceListener != nil }

    public func start() {
        guard deviceListener == nil else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.attachToDefaultDevice() }
        }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultDeviceAddress, .main, listener)
        deviceListener = listener
        attachToDefaultDevice()
    }

    public func stop() {
        detach()
        if let deviceListener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultDeviceAddress, .main, deviceListener)
        }
        deviceListener = nil
    }

    /// The output device changed (headphones plugged in, AirPods connected).
    /// Its current level becomes the baseline: switching is not a change.
    private func attachToDefaultDevice() {
        detach()
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &Self.defaultDeviceAddress, 0, nil, &size, &id)
        guard id != kAudioObjectUnknown else { return }
        device = id
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.valueChanged() }
        }
        let hasVolume = AudioObjectHasProperty(id, &Self.volumeAddress)
        if hasVolume { AudioObjectAddPropertyListenerBlock(id, &Self.volumeAddress, .main, listener) }
        if AudioObjectHasProperty(id, &Self.muteAddress) { AudioObjectAddPropertyListenerBlock(id, &Self.muteAddress, .main, listener) }
        valueListener = listener
        filter = VolumeChangeFilter(baseline: read())
        log.info("watching output device \(id), has volume: \(hasVolume)")
    }

    private func detach() {
        guard let valueListener, device != kAudioObjectUnknown else { return }
        AudioObjectRemovePropertyListenerBlock(device, &Self.volumeAddress, .main, valueListener)
        AudioObjectRemovePropertyListenerBlock(device, &Self.muteAddress, .main, valueListener)
        self.valueListener = nil
        device = AudioObjectID(kAudioObjectUnknown)
    }

    private func valueChanged() {
        guard let reading = read(), let event = filter.accept(reading) else { return }
        runtime.publish(event)
    }

    private func read() -> VolumeReading? {
        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &Self.volumeAddress, 0, nil, &size, &volume) == noErr else { return nil }
        var muted = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        let hasMute = AudioObjectGetPropertyData(device, &Self.muteAddress, 0, nil, &size, &muted) == noErr
        return VolumeReading(volume: Double(volume), isMuted: hasMute && muted != 0)
    }
}

struct VolumeReading: Equatable {
    var volume: Double
    var isMuted: Bool
}

/// Core Audio calls a listener more than once for one change (seen twice per
/// change in the pd-1 check), and for the mute and volume properties
/// separately. This lets through only readings that differ from the last one.
struct VolumeChangeFilter {
    private var last: VolumeReading?

    init(baseline: VolumeReading? = nil) {
        last = baseline.map(Self.rounded)
    }

    mutating func accept(_ reading: VolumeReading) -> OutputVolumeChanged? {
        let reading = Self.rounded(reading)
        guard reading != last else { return nil }
        last = reading
        return OutputVolumeChanged(volume: reading.volume, isMuted: reading.isMuted)
    }

    /// Float noise below a thousandth is not a change.
    private static func rounded(_ r: VolumeReading) -> VolumeReading {
        VolumeReading(volume: (min(max(r.volume, 0), 1) * 1000).rounded() / 1000, isMuted: r.isMuted)
    }
}
