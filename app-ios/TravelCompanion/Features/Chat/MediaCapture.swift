import AVFAudio
import ImageIO
import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum MediaCaptureError: LocalizedError {
    case unavailablePhotoRepresentation
    case cameraUnavailable
    case imageEncodingFailed
    case microphonePermissionDenied
    case recorderCouldNotStart

    var errorDescription: String? {
        switch self {
        case .unavailablePhotoRepresentation:
            "无法读取这张照片。它可能只保存在 iCloud，请先在系统照片中下载后重试。"
        case .cameraUnavailable:
            "此设备没有可用相机。"
        case .imageEncodingFailed:
            "无法保存拍摄的照片。"
        case .microphonePermissionDenied:
            "没有麦克风权限，无法录制语音消息。"
        case .recorderCouldNotStart:
            "录音器未能启动，请检查是否有其他 App 正在占用音频输入。"
        }
    }
}

@MainActor
enum MediaStaging {
    static func write(_ data: Data, fileExtension: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "TravelCompanionMedia", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder
            .appending(path: UUID().uuidString)
            .appendingPathExtension(fileExtension)
        try data.write(to: url, options: .atomic)
        return url
    }

    static func freshURL(fileExtension: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "TravelCompanionMedia", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
            .appending(path: UUID().uuidString)
            .appendingPathExtension(fileExtension)
    }
}

@MainActor
struct CameraCaptureSheet: View {
    @Environment(TravelCore.self) private var core
    @Environment(\.dismiss) private var dismiss

    let conversationID: String

    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                CameraPicker(
                    onImage: save,
                    onCancel: { dismiss() }
                )
                .ignoresSafeArea()
                .overlay {
                    if isSaving {
                        ProgressView("正在保存照片…")
                            .padding(18)
                            .background(.regularMaterial, in: .rect(cornerRadius: TCDesign.compactRadius))
                    }
                }
            } else {
                TCEmptyState(
                    title: "相机不可用",
                    message: "请改用照片选择器或导入图片文件。",
                    systemImage: "camera.fill.badge.ellipsis"
                )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { dismiss() }
                    }
                }
            }
        }
        .navigationBarHidden(true)
        .interactiveDismissDisabled(isSaving)
        .alert("无法发送照片", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "未知错误")
        }
    }

    private func save(_ image: UIImage) {
        guard !isSaving else { return }
        isSaving = true
        Task {
            do {
                guard let data = image.jpegData(compressionQuality: 0.84) else {
                    throw MediaCaptureError.imageEncodingFailed
                }
                let url = try MediaStaging.write(data, fileExtension: "jpg")
                await core.send(
                    .registerMedia(kind: .image, path: url.path, conversationID: conversationID)
                )
                if let error = core.lastError {
                    errorMessage = error.message
                } else {
                    dismiss()
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }
}

private struct CameraPicker: UIViewControllerRepresentable {
    let onImage: @MainActor (UIImage) -> Void
    let onCancel: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onImage: onImage, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier]
        picker.cameraCaptureMode = .photo
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onImage: @MainActor (UIImage) -> Void
        let onCancel: @MainActor () -> Void

        init(
            onImage: @escaping @MainActor (UIImage) -> Void,
            onCancel: @escaping @MainActor () -> Void
        ) {
            self.onImage = onImage
            self.onCancel = onCancel
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            guard let image = info[.originalImage] as? UIImage else {
                onCancel()
                return
            }
            onImage(image)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }
    }
}

@MainActor
@Observable
private final class VoiceCaptureController {
    private(set) var isRecording = false
    private(set) var isPlaying = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var level: Double = 0.05
    private(set) var recordedURL: URL?
    private(set) var permissionDenied = false
    var errorMessage: String?

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var meterTask: Task<Void, Never>?
    @ObservationIgnored private var playbackTask: Task<Void, Never>?

    func start() async {
        guard !isRecording else { return }
        errorMessage = nil

        let granted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        guard granted else {
            permissionDenied = true
            errorMessage = MediaCaptureError.microphonePermissionDenied.localizedDescription
            return
        }
        permissionDenied = false

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playAndRecord,
                mode: .spokenAudio,
                options: [.defaultToSpeaker, .allowBluetoothHFP]
            )
            try session.setActive(true)

            let url = try MediaStaging.freshURL(fileExtension: "m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 24_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.prepareToRecord(), recorder.record(forDuration: 300) else {
                throw MediaCaptureError.recorderCouldNotStart
            }

            self.recorder = recorder
            recordedURL = nil
            elapsed = 0
            level = 0.05
            isRecording = true
            beginMetering(recorder: recorder, url: url)
        } catch {
            errorMessage = error.localizedDescription
            deactivateAudioSession()
        }
    }

    func stop() {
        guard let recorder, isRecording else { return }
        recorder.stop()
        finishRecording(url: recorder.url)
    }

    func discard() {
        stopPlayback()
        if isRecording {
            recorder?.stop()
            isRecording = false
        }
        meterTask?.cancel()
        meterTask = nil
        if let recordedURL {
            try? FileManager.default.removeItem(at: recordedURL)
        }
        recorder = nil
        recordedURL = nil
        elapsed = 0
        level = 0.05
        deactivateAudioSession()
    }

    func togglePlayback() {
        guard let recordedURL else { return }
        if isPlaying {
            stopPlayback()
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
            let player = try AVAudioPlayer(contentsOf: recordedURL)
            guard player.prepareToPlay(), player.play() else {
                throw MediaCaptureError.recorderCouldNotStart
            }
            self.player = player
            isPlaying = true
            playbackTask?.cancel()
            playbackTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(player.duration))
                guard !Task.isCancelled else { return }
                self?.stopPlayback()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cleanup(keepFile: Bool) {
        if isRecording { recorder?.stop() }
        meterTask?.cancel()
        playbackTask?.cancel()
        player?.stop()
        if !keepFile, let recordedURL {
            try? FileManager.default.removeItem(at: recordedURL)
        }
        recorder = nil
        player = nil
        isRecording = false
        isPlaying = false
        deactivateAudioSession()
    }

    private func beginMetering(recorder: AVAudioRecorder, url: URL) {
        meterTask?.cancel()
        meterTask = Task { [weak self] in
            while !Task.isCancelled, recorder.isRecording {
                recorder.updateMeters()
                let decibels = recorder.averagePower(forChannel: 0)
                self?.elapsed = recorder.currentTime
                self?.level = max(0.05, min(1, pow(10, Double(decibels) / 32)))
                try? await Task.sleep(for: .milliseconds(80))
            }
            guard !Task.isCancelled, let self, self.isRecording else { return }
            self.finishRecording(url: url)
        }
    }

    private func finishRecording(url: URL) {
        meterTask?.cancel()
        meterTask = nil
        recordedURL = url
        isRecording = false
        level = 0.05
        recorder = nil
        deactivateAudioSession()
    }

    private func stopPlayback() {
        playbackTask?.cancel()
        playbackTask = nil
        player?.stop()
        player = nil
        isPlaying = false
        deactivateAudioSession()
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

@MainActor
struct VoiceRecorderSheet: View {
    @Environment(TravelCore.self) private var core
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let conversationID: String

    @State private var recorder = VoiceCaptureController()
    @State private var isSubmitting = false
    @State private var didSubmit = false

    var body: some View {
        VStack(spacing: 24) {
            HStack {
                Button("取消") { dismiss() }
                    .disabled(isSubmitting)
                Spacer()
                Text("录制语音")
                    .font(.headline)
                Spacer()
                Color.clear
                    .frame(width: 32, height: 1)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal)
            .padding(.vertical, 11)
            .background(.bar)

            Spacer()

            VoiceMeter(level: recorder.level, isActive: recorder.isRecording || recorder.isPlaying)
                .frame(height: 90)
                .padding(.horizontal, 28)

            Text(recorder.elapsed.formattedAudioDuration)
                .font(.system(size: 42, weight: .semibold, design: .rounded).monospacedDigit())
                .accessibilityLabel("录音时长 \(recorder.elapsed.formattedAudioDuration)")

            Text(statusText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let error = recorder.errorMessage {
                if recorder.permissionDenied {
                    TCNotice(
                        title: "录音不可用",
                        message: error,
                        systemImage: "mic.slash.fill",
                        tone: .danger,
                        actionTitle: "打开系统设置",
                        action: openSettings
                    )
                    .padding(.horizontal)
                } else {
                    TCNotice(
                        title: "录音不可用",
                        message: error,
                        systemImage: "mic.slash.fill",
                        tone: .danger
                    )
                    .padding(.horizontal)
                }
            }

            controls
                .padding(.horizontal)

            Spacer()
        }
        .tcPageBackground()
        .navigationBarHidden(true)
        .interactiveDismissDisabled(recorder.isRecording || isSubmitting)
        .onDisappear {
            recorder.cleanup(keepFile: didSubmit)
        }
    }

    @ViewBuilder
    private var controls: some View {
        if recorder.isRecording {
            Button {
                recorder.stop()
            } label: {
                Label("停止录音", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
        } else if recorder.recordedURL != nil {
            VStack(spacing: 12) {
                HStack {
                    Button {
                        recorder.discard()
                        Task { await recorder.start() }
                    } label: {
                        Label("重新录制", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        recorder.togglePlayback()
                    } label: {
                        Label(recorder.isPlaying ? "停止试听" : "试听", systemImage: recorder.isPlaying ? "stop.fill" : "play.fill")
                    }
                    .buttonStyle(.bordered)
                }

                Button(action: submit) {
                    HStack {
                        if isSubmitting { ProgressView() }
                        Label(isSubmitting ? "正在添加…" : "发送语音", systemImage: "arrow.up.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isSubmitting)
            }
        } else {
            Button {
                Task { await recorder.start() }
            } label: {
                Label("开始录音", systemImage: "mic.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private var statusText: String {
        if recorder.isRecording { return "正在录制 · 最长 5 分钟" }
        if recorder.isPlaying { return "正在试听本机录音" }
        if recorder.recordedURL != nil { return "录音仅保存在本机，点击发送后才会加入会话" }
        return "使用原生 AAC 音频容器，离线时会排队等待同步"
    }

    private func submit() {
        guard let url = recorder.recordedURL, !isSubmitting else { return }
        isSubmitting = true
        Task {
            await core.send(
                .registerMedia(kind: .voice, path: url.path, conversationID: conversationID)
            )
            if let error = core.lastError {
                recorder.errorMessage = error.message
                isSubmitting = false
            } else {
                didSubmit = true
                isSubmitting = false
                dismiss()
            }
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}

private struct VoiceMeter: View {
    let level: Double
    let isActive: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(0..<24, id: \.self) { index in
                let variance = 0.45 + abs(sin(Double(index) * 0.72)) * 0.55
                Capsule()
                    .fill(isActive ? Color.accentColor : Color.secondary.opacity(0.45))
                    .frame(width: 5, height: 12 + 70 * level * variance)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
        .animation(.smooth(duration: 0.08), value: level)
    }
}

@MainActor
@Observable
private final class VoicePlaybackController {
    private(set) var isPlaying = false
    var errorMessage: String?

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var completionTask: Task<Void, Never>?

    func toggle(path: String) {
        if isPlaying {
            stop()
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
            let player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
            guard player.prepareToPlay(), player.play() else {
                throw MediaCaptureError.recorderCouldNotStart
            }
            self.player = player
            isPlaying = true
            completionTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(player.duration))
                guard !Task.isCancelled else { return }
                self?.stop()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stop() {
        completionTask?.cancel()
        completionTask = nil
        player?.stop()
        player = nil
        isPlaying = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

@MainActor
struct VoiceMessageContent: View {
    let resource: ResourceSnapshot?
    let byteCount: String

    @State private var playback = VoicePlaybackController()

    var body: some View {
        HStack(spacing: 8) {
            Button {
                if let path = resource?.localPath {
                    playback.toggle(path: path)
                }
            } label: {
                Image(systemName: playback.isPlaying ? "stop.circle.fill" : "play.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(resource?.localPath == nil)
            .accessibilityLabel(playback.isPlaying ? "停止播放语音" : "播放语音")

            Image(systemName: "waveform")
            Text(byteCount)
                .font(.caption.monospacedDigit())
        }
        .accessibilityElement(children: .contain)
        .onDisappear { playback.stop() }
    }
}

@MainActor
struct LocalImageMessageContent: View {
    let resource: ResourceSnapshot?

    @State private var thumbnail: CGImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1, orientation: .up)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 210, height: 150)
                    .clipped()
                    .clipShape(.rect(cornerRadius: 10))
                    .accessibilityLabel("图片消息")
            } else {
                Label(resource?.localPath == nil ? "图片等待下载" : "正在生成预览", systemImage: "photo.fill")
                    .font(.body.weight(.medium))
                    .frame(minWidth: 150, minHeight: 72)
            }
        }
        .task(id: resource?.localPath) {
            guard let path = resource?.localPath else {
                thumbnail = nil
                return
            }
            thumbnail = await Self.makeThumbnail(path: path)
        }
    }

    private nonisolated static func makeThumbnail(path: String) async -> CGImage? {
        await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else {
                return nil
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 480,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
    }
}

private extension TimeInterval {
    var formattedAudioDuration: String {
        let totalSeconds = max(0, Int(self.rounded(.down)))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}
