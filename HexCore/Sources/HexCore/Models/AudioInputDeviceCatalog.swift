import CoreAudio
import Foundation

public struct AudioInputDevice: Identifiable, Equatable, Sendable {
  public let id: String
  public let name: String

  public init(id: String, name: String) {
    self.id = id
    self.name = name
  }
}

public enum AudioInputDeviceCatalog {
  public static func availableInputDevices() -> [AudioInputDevice] {
    availableInputDeviceIDs().compactMap { deviceID in
      guard let name = deviceName(for: deviceID) else {
        return nil
      }

      return AudioInputDevice(id: String(deviceID), name: name)
    }
  }

  public static func defaultInputDeviceID() -> String? {
    defaultInputDevice().map { String($0) }
  }

  public static func defaultInputDeviceName() -> String? {
    guard let deviceID = defaultInputDevice() else {
      return nil
    }

    return deviceName(for: deviceID)
  }

  public static func setDefaultInputDevice(id: String) throws {
    guard let rawValue = UInt32(id) else {
      throw AudioInputDeviceCatalogError.invalidDeviceID(id)
    }

    let deviceID = AudioDeviceID(rawValue)
    guard availableInputDeviceIDs().contains(deviceID) else {
      throw AudioInputDeviceCatalogError.unavailableDevice(id)
    }

    var device = deviceID
    let size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = audioPropertyAddress(kAudioHardwarePropertyDefaultInputDevice)
    let status = AudioObjectSetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      size,
      &device
    )

    guard status == noErr else {
      throw AudioInputDeviceCatalogError.setDefaultDeviceFailed(status)
    }
  }

  private static func audioPropertyAddress(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
  ) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: scope,
      mElement: element
    )
  }

  private static func allAudioDevices() -> [AudioDeviceID] {
    var propertySize: UInt32 = 0
    var address = audioPropertyAddress(kAudioHardwarePropertyDevices)
    let sizeStatus = AudioObjectGetPropertyDataSize(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &propertySize
    )

    guard sizeStatus == noErr else {
      return []
    }

    let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
    var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
    let readStatus = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &propertySize,
      &deviceIDs
    )

    guard readStatus == noErr else {
      return []
    }

    return deviceIDs
  }

  private static func availableInputDeviceIDs() -> [AudioDeviceID] {
    allAudioDevices().filter { deviceHasInput(for: $0) }
  }

  private static func defaultInputDevice() -> AudioDeviceID? {
    var deviceID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = audioPropertyAddress(kAudioHardwarePropertyDefaultInputDevice)
    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &size,
      &deviceID
    )

    guard status == noErr else {
      return nil
    }

    return deviceID
  }

  private static func deviceName(for deviceID: AudioDeviceID) -> String? {
    var address = audioPropertyAddress(kAudioDevicePropertyDeviceNameCFString)
    var size = UInt32(MemoryLayout<CFString?>.size)
    let storage = UnsafeMutableRawPointer.allocate(
      byteCount: Int(size),
      alignment: MemoryLayout<CFString?>.alignment
    )
    defer { storage.deallocate() }

    let status = AudioObjectGetPropertyData(
      deviceID,
      &address,
      0,
      nil,
      &size,
      storage
    )

    guard status == noErr else {
      return nil
    }

    return storage.load(as: CFString?.self) as String?
  }

  private static func deviceHasInput(for deviceID: AudioDeviceID) -> Bool {
    var address = audioPropertyAddress(
      kAudioDevicePropertyStreamConfiguration,
      scope: kAudioDevicePropertyScopeInput
    )
    var propertySize: UInt32 = 0
    let sizeStatus = AudioObjectGetPropertyDataSize(
      deviceID,
      &address,
      0,
      nil,
      &propertySize
    )

    guard sizeStatus == noErr else {
      return false
    }

    let storage = UnsafeMutableRawPointer.allocate(
      byteCount: Int(propertySize),
      alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { storage.deallocate() }

    let bufferList = storage.assumingMemoryBound(to: AudioBufferList.self)
    let readStatus = AudioObjectGetPropertyData(
      deviceID,
      &address,
      0,
      nil,
      &propertySize,
      bufferList
    )

    guard readStatus == noErr else {
      return false
    }

    let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
    return buffers.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
  }
}

public enum AudioInputDeviceCatalogError: LocalizedError, Sendable {
  case invalidDeviceID(String)
  case unavailableDevice(String)
  case setDefaultDeviceFailed(OSStatus)

  public var errorDescription: String? {
    switch self {
    case let .invalidDeviceID(id):
      return "Invalid input device identifier: \(id)"
    case let .unavailableDevice(id):
      return "Input device is not currently available: \(id)"
    case let .setDefaultDeviceFailed(status):
      return "Failed to switch the default input device (status \(status))"
    }
  }
}
