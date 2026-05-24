import Foundation

public struct HexSettingsStore: Sendable {
  public let url: URL

  public init(url: URL = URL.hexMigratedFileURL(named: "hex_settings.json")) {
    self.url = url
  }

  public func load() throws -> HexSettings {
    guard FileManager.default.fileExists(atPath: url.path) else {
      return HexSettings()
    }

    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(HexSettings.self, from: data)
  }

  public func save(_ settings: HexSettings) throws {
    let data = try JSONEncoder().encode(settings)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try data.write(to: url, options: .atomic)
  }
}
