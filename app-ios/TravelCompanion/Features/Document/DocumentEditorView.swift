import SwiftUI

@MainActor
struct DocumentEditorView: View {
    @Environment(TravelCore.self) private var core
    @Environment(\.dismiss) private var dismiss

    @State private var draft = ""
    @State private var baselineContent = ""
    @State private var parentRevisionID: String?
    @State private var isAcquiringLease = true
    @State private var ownsLease = false
    @State private var isSaving = false
    @State private var leaseError: String?
    @State private var saveError: String?
    @State private var didLoad = false
    @State private var isConfirmingDiscard = false

    private var lease: DocumentLeaseSnapshot? { core.snapshot.document.lease }
    private var hasChanges: Bool { draft != baselineContent }
    private var canEdit: Bool { ownsLease && !isSaving }

    var body: some View {
        VStack(spacing: 0) {
            if isAcquiringLease {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在申请短期编辑租约…")
                        .font(.subheadline)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(.regularMaterial)
            } else if let leaseError {
                TCNotice(
                    title: "当前无法编辑",
                    message: leaseError,
                    systemImage: "lock.fill",
                    tone: .warning
                )
                .padding()
            } else if let lease {
                HStack {
                    Label("编辑租约", systemImage: "lock.open.fill")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(lease.expiresAt.formattedRelative)到期")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(.green.opacity(0.09))
            }

            if let saveError {
                TCNotice(
                    title: "保存失败",
                    message: saveError,
                    systemImage: "exclamationmark.triangle.fill",
                    tone: .danger
                )
                .padding(.horizontal)
                .padding(.top, 8)
            }

            TextEditor(text: $draft)
                .font(.body.monospaced())
                .padding(.horizontal, 10)
                .scrollContentBackground(.hidden)
                .background(Color(.systemBackground))
                .disabled(!canEdit)
                .accessibilityLabel("Trip.md Markdown 编辑器")

            HStack {
                Text("\(draft.count) 个字符")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(hasChanges ? "有未保存更改" : "没有更改")
                    .font(.caption)
                    .foregroundStyle(hasChanges ? .orange : .secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .navigationTitle("编辑 Trip.md")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(hasChanges && canEdit)
        .toolbar {
            if hasChanges && canEdit {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { isConfirmingDiscard = true }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isSaving ? "保存中…" : "保存", action: save)
                    .disabled(!canEdit || !hasChanges)
            }
        }
        .task { await acquireLease() }
        .onDisappear(perform: releaseLeaseIfNeeded)
        .interactiveDismissDisabled(hasChanges && canEdit)
        .confirmationDialog(
            "放弃未保存的更改？",
            isPresented: $isConfirmingDiscard,
            titleVisibility: .visible
        ) {
            Button("放弃更改", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        } message: {
            Text("本机草稿尚未生成 revision。")
        }
    }

    private func loadDraftIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        let document = core.snapshot.document
        draft = document.content
        baselineContent = document.content
        parentRevisionID = document.revisionID
    }

    private func acquireLease() async {
        loadDraftIfNeeded()

        if let currentLease = core.snapshot.document.lease,
           !currentLease.isHeldByLocalPeer,
           currentLease.expiresAt > .now {
            isAcquiringLease = false
            leaseError = "\(currentLease.holderName) 正在编辑，租约将在 \(currentLease.expiresAt.formattedRelative)到期。"
            return
        }

        isAcquiringLease = true
        await core.send(.acquireDocumentLease)
        let acquiredLease = core.snapshot.document.lease
        ownsLease = acquiredLease?.isHeldByLocalPeer == true
        isAcquiringLease = false

        if !ownsLease {
            leaseError = core.snapshot.lifecycle.lastError ?? "编辑租约未授予，请稍后重试。"
        }
    }

    private func save() {
        guard canEdit, hasChanges else { return }
        isSaving = true
        saveError = nil
        let content = draft
        let parent = parentRevisionID
        Task {
            await core.send(.saveDocument(content: content, parentRevisionID: parent))
            if let error = core.lastError {
                saveError = error.message
                isSaving = false
            } else {
                await core.send(.releaseDocumentLease)
                ownsLease = false
                isSaving = false
                dismiss()
            }
        }
    }

    private func releaseLeaseIfNeeded() {
        guard ownsLease else { return }
        ownsLease = false
        Task { await core.send(.releaseDocumentLease) }
    }
}
