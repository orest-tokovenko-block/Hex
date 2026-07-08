import Foundation

protocol CLIAudioRecorder {
  func prepare() throws -> URL
  func startRecording() throws
  func stopRecording() async throws
}
