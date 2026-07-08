import AVFoundation
import CoreAudio
import Foundation

@available(macOS 14.4, *)
final class SystemAudioTapRecorder: NSObject, CLIAudioRecorder, @unchecked Sendable {
  private var tapID = AudioObjectID(kAudioObjectUnknown)
  private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
  private var ioProcID: AudioDeviceIOProcID?
  private var tapFormat: AVAudioFormat?
  private var audioFile: AVAudioFile?

  private let queue = DispatchQueue(label: "com.kitlangton.Hex.cli.system-audio-tap")
  private let recordingURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("hex-cli-system-audio-\(UUID().uuidString).wav")

  func prepare() throws -> URL {
    let tapDescription = CATapDescription(monoGlobalTapButExcludeProcesses: [])
    tapDescription.name = "Hex CLI System Audio Tap"
    tapDescription.isPrivate = true
    tapDescription.muteBehavior = .unmuted

    var tap = AudioObjectID(kAudioObjectUnknown)
    let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &tap)
    guard tapStatus == noErr else {
      throw SystemAudioTapRecorderError.tapCreationFailed(tapStatus)
    }
    tapID = tap

    let format = try readTapFormat(tapID)
    tapFormat = format

    let outputUID = defaultOutputDeviceUID()
    let aggregateUID = "com.kitlangton.Hex.cli.tap-\(UUID().uuidString)"
    var description: [String: Any] = [
      kAudioAggregateDeviceNameKey: "Hex CLI System Audio",
      kAudioAggregateDeviceUIDKey: aggregateUID,
      kAudioAggregateDeviceIsPrivateKey: true,
      kAudioAggregateDeviceIsStackedKey: false,
      kAudioAggregateDeviceTapAutoStartKey: true,
      kAudioAggregateDeviceTapListKey: [
        [
          kAudioSubTapDriftCompensationKey: true,
          kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
        ],
      ],
    ]

    if let outputUID {
      description[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
      description[kAudioAggregateDeviceSubDeviceListKey] = [
        [kAudioSubDeviceUIDKey: outputUID],
      ]
    }

    var aggregate = AudioObjectID(kAudioObjectUnknown)
    let aggregateStatus = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate)
    guard aggregateStatus == noErr else {
      cleanupTap()
      throw SystemAudioTapRecorderError.aggregateCreationFailed(aggregateStatus)
    }
    aggregateDeviceID = aggregate

    audioFile = try AVAudioFile(
      forWriting: recordingURL,
      settings: format.settings,
      commonFormat: format.commonFormat,
      interleaved: format.isInterleaved
    )

    var proc: AudioDeviceIOProcID?
    let procStatus = AudioDeviceCreateIOProcIDWithBlock(
      &proc,
      aggregateDeviceID,
      queue
    ) { [weak self] _, inputData, _, _, _ in
      self?.handle(inputData)
    }
    guard procStatus == noErr, let proc else {
      cleanup()
      throw SystemAudioTapRecorderError.ioProcCreationFailed(procStatus)
    }
    ioProcID = proc

    return recordingURL
  }

  func startRecording() throws {
    let status = AudioDeviceStart(aggregateDeviceID, ioProcID)
    guard status == noErr else {
      throw SystemAudioTapRecorderError.startFailed(status)
    }
  }

  func stopRecording() async throws {
    if let ioProcID {
      AudioDeviceStop(aggregateDeviceID, ioProcID)
      AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
      self.ioProcID = nil
    }

    // Drain any in-flight callbacks and close the file for a valid header.
    queue.sync {
      self.audioFile = nil
    }

    cleanupAggregate()
    cleanupTap()

    let attributes = try FileManager.default.attributesOfItem(atPath: recordingURL.path)
    let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
    guard size > 0 else {
      throw SystemAudioTapRecorderError.noAudioCaptured
    }
  }

  private func handle(_ inputData: UnsafePointer<AudioBufferList>) {
    guard let tapFormat,
          let audioFile,
          let buffer = AVAudioPCMBuffer(pcmFormat: tapFormat, bufferListNoCopy: inputData)
    else {
      return
    }

    guard buffer.frameLength > 0 else {
      return
    }

    try? audioFile.write(from: buffer)
  }

  private func readTapFormat(_ tap: AudioObjectID) throws -> AVAudioFormat {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioTapPropertyFormat,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var asbd = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    let status = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd)
    guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
      throw SystemAudioTapRecorderError.formatUnavailable(status)
    }
    return format
  }

  private func defaultOutputDeviceUID() -> String? {
    var device = AudioObjectID(kAudioObjectUnknown)
    var deviceSize = UInt32(MemoryLayout<AudioObjectID>.size)
    var deviceAddress = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    let deviceStatus = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &deviceAddress,
      0,
      nil,
      &deviceSize,
      &device
    )
    guard deviceStatus == noErr, device != kAudioObjectUnknown else {
      return nil
    }

    var uidAddress = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDeviceUID,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var uid: CFString?
    var uidSize = UInt32(MemoryLayout<CFString?>.size)
    let uidStatus = withUnsafeMutablePointer(to: &uid) {
      AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &uidSize, $0)
    }
    guard uidStatus == noErr else {
      return nil
    }
    return uid as String?
  }

  private func cleanup() {
    cleanupAggregate()
    cleanupTap()
    audioFile = nil
  }

  private func cleanupAggregate() {
    guard aggregateDeviceID != kAudioObjectUnknown else {
      return
    }
    AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
    aggregateDeviceID = kAudioObjectUnknown
  }

  private func cleanupTap() {
    guard tapID != kAudioObjectUnknown else {
      return
    }
    AudioHardwareDestroyProcessTap(tapID)
    tapID = kAudioObjectUnknown
  }
}

private enum SystemAudioTapRecorderError: LocalizedError {
  case tapCreationFailed(OSStatus)
  case aggregateCreationFailed(OSStatus)
  case ioProcCreationFailed(OSStatus)
  case formatUnavailable(OSStatus)
  case startFailed(OSStatus)
  case noAudioCaptured

  var errorDescription: String? {
    switch self {
    case let .tapCreationFailed(status):
      return "Could not create the system audio tap (status \(status)). Grant your terminal audio recording access in System Settings -> Privacy & Security"
    case let .aggregateCreationFailed(status):
      return "Could not create the system audio capture device (status \(status))"
    case let .ioProcCreationFailed(status):
      return "Could not start the system audio capture callback (status \(status))"
    case let .formatUnavailable(status):
      return "Could not read the system audio format (status \(status))"
    case let .startFailed(status):
      return "Could not start system audio capture (status \(status))"
    case .noAudioCaptured:
      return "No system audio was captured. Make sure audio was playing while recording"
    }
  }
}
