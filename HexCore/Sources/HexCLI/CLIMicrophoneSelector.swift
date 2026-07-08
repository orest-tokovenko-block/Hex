import Darwin
import Foundation
import HexCore

enum CLICaptureSource: Equatable {
  case microphone(inputDeviceID: String?)
  case systemAudio
}

struct CLICaptureSelection: Equatable {
  let source: CLICaptureSource
  let displayName: String
}

struct CLIMicrophoneSelector {
  private let settingsStore = HexSettingsStore()

  private var systemAudioAvailable: Bool {
    if #available(macOS 14.4, *) {
      return true
    }
    return false
  }

  func resolveSelection(requestedDevice: String?) throws -> CLICaptureSelection {
    let devices = AudioInputDeviceCatalog.availableInputDevices()
    let defaultName = AudioInputDeviceCatalog.defaultInputDeviceName()
    let settings = (try? settingsStore.load()) ?? HexSettings()

    if let requestedDevice {
      return try resolveExplicitSelection(requestedDevice, availableDevices: devices, defaultName: defaultName)
    }

    if cliInputIsInteractive() {
      return try promptForSelection(availableDevices: devices, defaultName: defaultName, settings: settings)
    }

    if let savedSelection = savedSelection(from: settings, availableDevices: devices) {
      return savedSelection
    }

    if settings.selectedMicrophoneID != nil {
      fputs("Saved microphone is unavailable. Using system default.\n", stderr)
    }

    return systemDefaultSelection(defaultName)
  }

  private func resolveExplicitSelection(
    _ requestedDevice: String,
    availableDevices: [AudioInputDevice],
    defaultName: String?
  ) throws -> CLICaptureSelection {
    let trimmed = requestedDevice.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalized = trimmed.lowercased()

    if ["system-audio", "systemaudio", "output", "loopback"].contains(normalized) {
      guard systemAudioAvailable else {
        throw CLIMicrophoneSelectorError.systemAudioUnavailable
      }
      return systemAudioSelection()
    }

    if ["default", "system", "system-default"].contains(normalized) {
      return systemDefaultSelection(defaultName)
    }

    if let exactID = availableDevices.first(where: { $0.id == trimmed }) {
      return .init(source: .microphone(inputDeviceID: exactID.id), displayName: exactID.name)
    }

    let exactNameMatches = availableDevices.filter {
      $0.name.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }
    if exactNameMatches.count == 1, let match = exactNameMatches.first {
      return .init(source: .microphone(inputDeviceID: match.id), displayName: match.name)
    }
    if exactNameMatches.count > 1 {
      throw CLIMicrophoneSelectorError.ambiguousInputDevice(trimmed, exactNameMatches.map(\.name))
    }

    let partialMatches = availableDevices.filter {
      $0.name.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
    if partialMatches.count == 1, let match = partialMatches.first {
      return .init(source: .microphone(inputDeviceID: match.id), displayName: match.name)
    }
    if partialMatches.count > 1 {
      throw CLIMicrophoneSelectorError.ambiguousInputDevice(trimmed, partialMatches.map(\.name))
    }

    throw CLIMicrophoneSelectorError.unknownInputDevice(trimmed)
  }

  private func promptForSelection(
    availableDevices: [AudioInputDevice],
    defaultName: String?,
    settings: HexSettings
  ) throws -> CLICaptureSelection {
    if settings.selectedMicrophoneID != nil,
       savedSelection(from: settings, availableDevices: availableDevices) == nil
    {
      fputs("Saved microphone is unavailable. Choose a device or use the current system default.\n", stderr)
    }

    let defaultSelection = savedSelection(from: settings, availableDevices: availableDevices)
      ?? systemDefaultSelection(defaultName)

    var options = [systemDefaultSelection(defaultName)]
      + availableDevices.map { CLICaptureSelection(source: .microphone(inputDeviceID: $0.id), displayName: $0.name) }

    if systemAudioAvailable {
      options.append(systemAudioSelection())
    }

    let defaultIndex = options.firstIndex(of: defaultSelection) ?? 0

    fputs("\nChoose input device:\n\n", stderr)
    for (index, option) in options.enumerated() {
      let suffix = index == defaultIndex ? " (current)" : ""
      fputs("  [\(index + 1)] \(option.displayName)\(suffix)\n", stderr)
    }
    fputs("\nEnter number [\(defaultIndex + 1)]: ", stderr)

    let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let choice = input.isEmpty ? defaultIndex + 1 : Int(input)
    guard let choice, (1...options.count).contains(choice) else {
      throw CLIMicrophoneSelectorError.invalidDeviceChoice
    }

    let selection = options[choice - 1]
    if case let .microphone(inputDeviceID) = selection.source {
      persistSelection(inputDeviceID, into: settings)
    }
    return selection
  }

  private func savedSelection(
    from settings: HexSettings,
    availableDevices: [AudioInputDevice]
  ) -> CLICaptureSelection? {
    guard let selectedMicrophoneID = settings.selectedMicrophoneID,
          let device = availableDevices.first(where: { $0.id == selectedMicrophoneID })
    else {
      return nil
    }

    return .init(source: .microphone(inputDeviceID: device.id), displayName: device.name)
  }

  private func systemDefaultSelection(_ defaultName: String?) -> CLICaptureSelection {
    let label: String
    if let defaultName, !defaultName.isEmpty {
      label = "System Default (\(defaultName))"
    } else {
      label = "System Default"
    }

    return .init(source: .microphone(inputDeviceID: nil), displayName: label)
  }

  private func systemAudioSelection() -> CLICaptureSelection {
    .init(source: .systemAudio, displayName: "System Audio (capture output)")
  }

  private func persistSelection(_ inputDeviceID: String?, into settings: HexSettings) {
    var updatedSettings = settings
    updatedSettings.selectedMicrophoneID = inputDeviceID

    do {
      try settingsStore.save(updatedSettings)
    } catch {
      fputs("Warning: Could not save microphone selection (\(error.localizedDescription))\n", stderr)
    }
  }
}

private enum CLIMicrophoneSelectorError: LocalizedError {
  case invalidDeviceChoice
  case unknownInputDevice(String)
  case ambiguousInputDevice(String, [String])
  case systemAudioUnavailable

  var errorDescription: String? {
    switch self {
    case .invalidDeviceChoice:
      return "Invalid input device choice"
    case let .unknownInputDevice(query):
      return "No input device matched '\(query)'. Use --device default, --device system-audio, a device ID, or an exact device name"
    case let .ambiguousInputDevice(query, matches):
      return "Input device '\(query)' matched multiple devices: \(matches.joined(separator: ", "))"
    case .systemAudioUnavailable:
      return "System audio capture requires macOS 14.4 or later"
    }
  }
}

func cliInputIsInteractive() -> Bool {
  isatty(STDIN_FILENO) == 1
}
