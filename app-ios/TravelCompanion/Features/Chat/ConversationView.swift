import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

@MainActor
struct ConversationView: View {
    @Environment(TravelCore.self) private var core
    @Environment(AppRouter.self) private var router

    let conversationID: String

    @State private var draft = ""
    @State private var isSending = false
    @State private var attachmentKind: MediaKind?
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var attachmentError: String?
    @State private var isRegisteringAttachment = false
    @FocusState private var isComposerFocused: Bool

    private var conversation: ConversationSnapshot? {
        core.snapshot.conversations.first { $0.id == conversationID }
    }

    private var messages: [MessageSnapshot] {
        conversation?.messages.sorted { $0.createdAt < $1.createdAt } ?? []
    }

    private var callPeerID: String? {
        guard let conversation, conversation.kind.lowercased() != "group" else { return nil }
        return conversation.participantIDs.first { $0 != core.snapshot.identity.peerID }
    }

    var body: some View {
        Group {
            if let conversation {
                messageContent(conversation)
            } else {
                TCEmptyState(
                    title: "会话不可用",
                    message: "它可能已在群组同步后被移除。",
                    systemImage: "bubble.left.and.exclamationmark.bubble.right"
                )
            }
        }
        .navigationTitle(conversation?.title ?? "消息")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let callPeerID {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("语音通话", systemImage: "phone") {
                        Task { await core.send(.startCall(peerID: callPeerID)) }
                    }
                    .disabled(core.snapshot.activeCall != nil)
                }
            }
        }
        .fileImporter(
            isPresented: Binding(
                get: { attachmentKind != nil },
                set: { if !$0 { attachmentKind = nil } }
            ),
            allowedContentTypes: allowedAttachmentTypes,
            allowsMultipleSelection: false,
            onCompletion: importAttachment
        )
        .alert("无法添加附件", isPresented: Binding(
            get: { attachmentError != nil },
            set: { if !$0 { attachmentError = nil } }
        )) {
            Button("好") { attachmentError = nil }
        } message: {
            Text(attachmentError ?? "未知错误")
        }
    }

    private func messageContent(_ conversation: ConversationSnapshot) -> some View {
        ScrollViewReader { proxy in
            Group {
                if messages.isEmpty {
                    TCEmptyState(
                        title: "开始对话",
                        message: "离线时发送的消息会先安全保存在本机，重连后自动补发。",
                        systemImage: "text.bubble"
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(messages) { message in
                                MessageBubble(message: message)
                                    .id(message.id)
                            }
                        }
                        .padding(.horizontal, TCDesign.pagePadding)
                        .padding(.vertical, 12)
                    }
                    .scrollDismissesKeyboard(.interactively)
                }
            }
            .tcPageBackground()
            .safeAreaInset(edge: .bottom, spacing: 0) {
                MessageComposer(
                    draft: $draft,
                    selectedPhoto: $selectedPhoto,
                    isSending: isSending,
                    isRegisteringAttachment: isRegisteringAttachment,
                    onSend: sendText,
                    onOpenCamera: openCamera,
                    onRecordVoice: { router.present(.recordVoice(conversationID: conversationID)) },
                    onImportImage: { attachmentKind = .image },
                    onImportVoice: { attachmentKind = .voice }
                )
                .focused($isComposerFocused)
            }
            .onChange(of: selectedPhoto) { _, newValue in
                guard let newValue else { return }
                Task { await importPhoto(newValue) }
            }
            .onChange(of: messages.count) { _, _ in
                guard let lastID = messages.last?.id else { return }
                withAnimation { proxy.scrollTo(lastID, anchor: .bottom) }
            }
            .onAppear {
                if let lastID = messages.last?.id {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
        }
        .accessibilityIdentifier("conversation.\(conversation.id)")
    }

    private var allowedAttachmentTypes: [UTType] {
        guard let attachmentKind else { return [.data] }
        switch attachmentKind {
        case .image: return [.image]
        case .voice: return [.audio]
        }
    }

    private func sendText() {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !isSending else { return }
        draft = ""
        isSending = true
        Task {
            await core.send(.sendText(conversationID: conversationID, body: body))
            if core.lastError != nil {
                draft = draft.isEmpty ? body : body + "\n" + draft
            }
            isSending = false
        }
    }

    private func openCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            attachmentError = "此设备没有可用相机。请改用照片选择器或文件导入。"
            return
        }
        router.present(.camera(conversationID: conversationID))
    }

    private func importPhoto(_ item: PhotosPickerItem) async {
        isRegisteringAttachment = true
        defer {
            isRegisteringAttachment = false
            selectedPhoto = nil
        }

        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw MediaCaptureError.unavailablePhotoRepresentation
            }
            let type = item.supportedContentTypes.first { $0.conforms(to: .image) }
            let fileExtension = type?.preferredFilenameExtension ?? "jpg"
            let stagedURL = try MediaStaging.write(data, fileExtension: fileExtension)
            await core.send(
                .registerMedia(kind: .image, path: stagedURL.path, conversationID: conversationID)
            )
            if let error = core.lastError {
                attachmentError = error.message
            }
        } catch {
            attachmentError = error.localizedDescription
        }
    }

    private func importAttachment(_ result: Result<[URL], Error>) {
        guard let kind = attachmentKind else { return }
        attachmentKind = nil
        do {
            guard let sourceURL = try result.get().first else { return }
            isRegisteringAttachment = true
            Task {
                do {
                    let stagedURL = try stageAttachment(sourceURL)
                    await core.send(
                        .registerMedia(
                            kind: kind,
                            path: stagedURL.path,
                            conversationID: conversationID
                        )
                    )
                    if let error = core.lastError {
                        attachmentError = error.message
                    }
                } catch {
                    attachmentError = error.localizedDescription
                }
                isRegisteringAttachment = false
            }
        } catch {
            attachmentError = error.localizedDescription
        }
    }

    private func stageAttachment(_ sourceURL: URL) throws -> URL {
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess { sourceURL.stopAccessingSecurityScopedResource() }
        }

        let folder = FileManager.default.temporaryDirectory
            .appending(path: "TravelCompanionMedia", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder
            .appending(path: UUID().uuidString)
            .appendingPathExtension(sourceURL.pathExtension)
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return destination
    }
}

private struct MessageComposer: View {
    @Binding var draft: String
    @Binding var selectedPhoto: PhotosPickerItem?
    let isSending: Bool
    let isRegisteringAttachment: Bool
    let onSend: () -> Void
    let onOpenCamera: () -> Void
    let onRecordVoice: () -> Void
    let onImportImage: () -> Void
    let onImportVoice: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Menu {
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Label("从照片中选择", systemImage: "photo.on.rectangle")
                }
                Button("拍摄照片", systemImage: "camera", action: onOpenCamera)
                Button("录制语音", systemImage: "mic", action: onRecordVoice)
                Divider()
                Button("导入图片文件", systemImage: "photo.badge.plus", action: onImportImage)
                Button("导入语音文件", systemImage: "waveform.badge.plus", action: onImportVoice)
            } label: {
                if isRegisteringAttachment {
                    ProgressView()
                        .frame(width: 30, height: 30)
                } else {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .frame(width: 30, height: 30)
                }
            }
            .disabled(isRegisteringAttachment)
            .accessibilityLabel("添加图片或语音")

            TextField("离线消息", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(TCDesign.subtleBackground, in: .rect(cornerRadius: 18))
                .submitLabel(.send)
                .onSubmit(onSend)

            Button(action: onSend) {
                if isSending {
                    ProgressView()
                        .frame(width: 32, height: 32)
                } else {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                }
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
            .accessibilityLabel("发送消息")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.regularMaterial)
    }
}

private struct MessageBubble: View {
    let message: MessageSnapshot

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.isOutgoing { Spacer(minLength: 48) }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 4) {
                if !message.isOutgoing {
                    Text(message.senderName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }

                VStack(alignment: .leading, spacing: 8) {
                    messageBody
                    if let resource = message.resource,
                       !["complete", "completed", "available"].contains(resource.state.lowercased()) {
                        ProgressView(value: resource.progress)
                            .tint(message.isOutgoing ? .white : .accentColor)
                            .accessibilityLabel("附件传输进度")
                            .accessibilityValue(resource.progress.formatted(.percent.precision(.fractionLength(0))))
                        ResourceTransferControls(resource: resource)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .foregroundStyle(message.isOutgoing ? Color.white : Color.primary)
                .background(
                    message.isOutgoing ? Color.accentColor : TCDesign.cardBackground,
                    in: .rect(cornerRadius: 16)
                )

                HStack(spacing: 5) {
                    Text(message.createdAt.formatted(date: .omitted, time: .shortened))
                    if message.isOutgoing {
                        DeliveryIndicator(delivery: message.delivery)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            }

            if !message.isOutgoing { Spacer(minLength: 48) }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var messageBody: some View {
        switch message.kind.lowercased() {
        case "image":
            LocalImageMessageContent(resource: message.resource)
        case "voice", "audio":
            VoiceMessageContent(resource: message.resource, byteCount: byteCount)
        default:
            Text(message.text ?? "")
                .textSelection(.enabled)
        }
    }

    private var byteCount: String {
        guard let bytes = message.resource?.byteCount else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

private struct ResourceTransferControls: View {
    @Environment(TravelCore.self) private var core

    let resource: ResourceSnapshot

    private var state: String { resource.state.lowercased() }
    private var canRetry: Bool {
        ["failed", "error", "cancelled", "canceled"].contains(state)
    }
    private var canCancel: Bool {
        ["queued", "pending", "transferring", "sending", "receiving", "downloading", "uploading"].contains(state)
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(displayState)
                .font(.caption)
            Spacer(minLength: 4)
            if canRetry {
                Button("重试", systemImage: "arrow.clockwise") {
                    Task { await core.send(.retryResource(id: resource.id)) }
                }
                .font(.caption.weight(.semibold))
            }
            if canCancel {
                Button("取消", systemImage: "xmark.circle") {
                    Task { await core.send(.cancelResource(id: resource.id)) }
                }
                .font(.caption.weight(.semibold))
            }
        }
        .buttonStyle(.borderless)
        .accessibilityElement(children: .contain)
    }

    private var displayState: String {
        switch state {
        case "failed", "error": "传输失败"
        case "cancelled", "canceled": "已取消"
        case "queued", "pending": "等待传输"
        case "transferring", "sending", "receiving", "downloading", "uploading": "正在传输"
        default: resource.state
        }
    }
}

private struct DeliveryIndicator: View {
    let delivery: DeliverySnapshot

    var body: some View {
        Label(statusText, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .foregroundStyle(isError ? .red : .secondary)
            .accessibilityLabel("发送状态：\(statusText)")
    }

    private var normalizedPhase: String { delivery.phase.lowercased() }
    private var isError: Bool {
        delivery.error != nil || ["failed", "error"].contains(normalizedPhase)
    }
    private var statusText: String {
        if isError { return delivery.error ?? "发送失败" }
        switch normalizedPhase {
        case "local", "persisted", "queued": return "已排队"
        case "relay", "sending": return "正在发送"
        case "delivered", "complete", "completed": return "已送达"
        default: return delivery.phase
        }
    }
    private var systemImage: String {
        if isError { return "exclamationmark.circle" }
        switch normalizedPhase {
        case "delivered", "complete", "completed": return "checkmark.circle.fill"
        case "relay", "sending": return "arrow.up.circle"
        default: return "clock"
        }
    }
}
