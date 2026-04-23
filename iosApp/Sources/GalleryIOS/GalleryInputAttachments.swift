import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct ChatInputAttachment: Identifiable, Hashable, Sendable {
  enum Kind: Sendable {
    case image
    case audio
  }

  let id = UUID()
  let kind: Kind
  let url: URL
  let displayName: String
  let shouldPersistInWorkspace: Bool

  var symbol: String {
    switch kind {
    case .image: return "photo"
    case .audio: return "waveform"
    }
  }

  var inferenceAttachment: GalleryInferenceAttachment {
    GalleryInferenceAttachment(
      kind: kind == .image ? .image : .audio,
      path: url.path,
      displayName: displayName
    )
  }
}

enum ChatInputAttachmentStore {
  static func savePickedPhoto(_ item: PhotosPickerItem) async throws -> ChatInputAttachment {
    guard let data = try await item.loadTransferable(type: Data.self) else {
      throw AttachmentError.couldNotReadPhoto
    }
    let fileExtension = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
    let url = try write(data: data, fileExtension: fileExtension)
    return ChatInputAttachment(kind: .image, url: url, displayName: url.lastPathComponent, shouldPersistInWorkspace: true)
  }

  static func saveCameraImage(_ image: UIImage) throws -> ChatInputAttachment {
    guard let data = image.jpegData(compressionQuality: 0.88) else {
      throw AttachmentError.couldNotEncodeImage
    }
    let url = try write(data: data, fileExtension: "jpg")
    return ChatInputAttachment(kind: .image, url: url, displayName: url.lastPathComponent, shouldPersistInWorkspace: true)
  }

  static func copyAudioFile(
    from sourceURL: URL,
    shouldPersistInWorkspace: Bool = false
  ) throws -> ChatInputAttachment {
    let didStartAccessing = sourceURL.startAccessingSecurityScopedResource()
    defer {
      if didStartAccessing { sourceURL.stopAccessingSecurityScopedResource() }
    }
    let ext = sourceURL.pathExtension.isEmpty ? "wav" : sourceURL.pathExtension
    let destination = try attachmentDirectory().appendingPathComponent("\(UUID().uuidString).\(ext)")
    if FileManager.default.fileExists(atPath: destination.path) {
      try FileManager.default.removeItem(at: destination)
    }
    try FileManager.default.copyItem(at: sourceURL, to: destination)
    return ChatInputAttachment(
      kind: .audio,
      url: destination,
      displayName: sourceURL.lastPathComponent,
      shouldPersistInWorkspace: shouldPersistInWorkspace
    )
  }

  static func newRecordingURL() throws -> URL {
    try attachmentDirectory().appendingPathComponent("recording-\(UUID().uuidString).wav")
  }

  private static func write(data: Data, fileExtension: String) throws -> URL {
    let url = try attachmentDirectory().appendingPathComponent("\(UUID().uuidString).\(fileExtension)")
    try data.write(to: url, options: .atomic)
    return url
  }

  private static func attachmentDirectory() throws -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    let directory = base.appendingPathComponent("GalleryIOS/InputAttachments", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  enum AttachmentError: LocalizedError {
    case couldNotReadPhoto
    case couldNotEncodeImage

    var errorDescription: String? {
      switch self {
      case .couldNotReadPhoto: return "Could not read the selected photo."
      case .couldNotEncodeImage: return "Could not encode the camera image."
      }
    }
  }
}

struct CameraCaptureView: UIViewControllerRepresentable {
  let onImage: (UIImage) -> Void
  let onCancel: () -> Void

  func makeUIViewController(context: Context) -> UIImagePickerController {
    let picker = UIImagePickerController()
    picker.sourceType = .camera
    picker.delegate = context.coordinator
    return picker
  }

  func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

  func makeCoordinator() -> Coordinator {
    Coordinator(onImage: onImage, onCancel: onCancel)
  }

  final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    let onImage: (UIImage) -> Void
    let onCancel: () -> Void

    init(onImage: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
      self.onImage = onImage
      self.onCancel = onCancel
    }

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
      if let image = info[.originalImage] as? UIImage {
        onImage(image)
      } else {
        onCancel()
      }
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
      onCancel()
    }
  }
}

struct AudioRecorderSheet: View {
  let title: String
  let idleTitle: String
  let recordingTitle: String
  let stopButtonTitle: String
  let onComplete: (URL) -> Void
  let onCancel: () -> Void

  @State private var recorder: AVAudioRecorder?
  @State private var recordingURL: URL?
  @State private var isRecording = false
  @State private var errorMessage: String?

  var body: some View {
    NavigationStack {
      VStack(spacing: 20) {
        Image(systemName: isRecording ? "waveform.circle.fill" : "mic.circle.fill")
          .font(.system(size: 68, weight: .semibold))
          .foregroundStyle(isRecording ? Color.red : Color.accentColor)
        Text(isRecording ? recordingTitle : idleTitle)
          .font(.headline)
        if let errorMessage {
          Text(errorMessage)
            .font(.footnote)
            .foregroundStyle(.red)
            .multilineTextAlignment(.center)
        }
        Button {
          isRecording ? stopRecording() : startRecording()
        } label: {
          Label(isRecording ? stopButtonTitle : "Start recording", systemImage: isRecording ? "stop.fill" : "record.circle")
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding()
            .background(isRecording ? Color.red.opacity(0.15) : Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        Spacer()
      }
      .padding()
      .navigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            recorder?.stop()
            onCancel()
          }
        }
      }
    }
  }

  private func startRecording() {
    Task {
      let granted = await AVAudioApplication.requestRecordPermission()
      await MainActor.run {
        guard granted else {
          errorMessage = "Microphone permission is required."
          return
        }
        do {
          let url = try ChatInputAttachmentStore.newRecordingURL()
          let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
          ]
          let recorder = try AVAudioRecorder(url: url, settings: settings)
          recorder.record()
          self.recorder = recorder
          self.recordingURL = url
          self.isRecording = true
          self.errorMessage = nil
        } catch {
          errorMessage = error.localizedDescription
        }
      }
    }
  }

  private func stopRecording() {
    recorder?.stop()
    isRecording = false
    if let recordingURL {
      onComplete(recordingURL)
    } else {
      onCancel()
    }
  }
}
