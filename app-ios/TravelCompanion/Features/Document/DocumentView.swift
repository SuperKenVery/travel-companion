import SwiftUI

@MainActor
struct DocumentView: View {
    @Environment(TravelCore.self) private var core
    @Environment(AppRouter.self) private var router

    private var snapshot: AppSnapshot { core.snapshot }
    private var document: DocumentSnapshot { snapshot.document }
    private var isLockedByAnotherMember: Bool {
        document.lease.map { !$0.isHeldByLocalPeer && $0.expiresAt > .now } ?? false
    }

    var body: some View {
        Group {
            if snapshot.group == nil {
                TCEmptyState(
                    title: "加入群组后共享行程",
                    message: "每个群组有一份可离线查看的 Trip.md。",
                    systemImage: "doc.badge.ellipsis"
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        DocumentRevisionCard(document: document)

                        if let lease = document.lease, lease.expiresAt > .now {
                            LeaseStatusCard(lease: lease)
                        }

                        if !document.conflicts.isEmpty {
                            conflictSection
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            TCSectionHeader(
                                title: "预览",
                                subtitle: "预览与原生文本编辑是两个独立模式。",
                                systemImage: "eye"
                            )
                            Divider()
                            MarkdownPreview(content: document.content)
                        }
                        .tcCard()
                    }
                    .padding(TCDesign.pagePadding)
                }
                .tcPageBackground()
            }
        }
        .navigationTitle("Trip.md")
        .toolbar {
            if snapshot.group != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        DocumentEditorView()
                    } label: {
                        Label("编辑", systemImage: "square.and.pencil")
                    }
                    .disabled(isLockedByAnotherMember)
                    .accessibilityHint(
                        isLockedByAnotherMember
                            ? "当前由其他成员编辑"
                            : "进入独立文本编辑模式并申请编辑租约"
                    )
                }
            }
        }
    }

    private var conflictSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            TCNotice(
                title: "发现 \(document.conflicts.count) 份冲突副本",
                message: "网络分区期间产生的内容已完整保留。请逐份查看后手动整理到主文档。",
                systemImage: "arrow.triangle.branch",
                tone: .warning
            )

            ForEach(document.conflicts) { conflict in
                Button {
                    router.present(.documentConflict(id: conflict.id))
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(conflict.authorName)
                                .font(.headline)
                            Text(conflict.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("查看 \(conflict.authorName) 的冲突副本")
            }
        }
        .tcCard()
    }
}

private struct DocumentRevisionCard: View {
    let document: DocumentSnapshot

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text.fill")
                .font(.title)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("最后同步的版本")
                    .font(.headline)
                Text(revisionDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 4)

            TCStatusPill(
                text: document.revisionID == nil ? "本地初稿" : "可离线查看",
                tone: document.revisionID == nil ? .neutral : .success,
                systemImage: "checkmark.icloud"
            )
        }
        .tcCard()
        .accessibilityElement(children: .combine)
    }

    private var revisionDescription: String {
        guard let revisionID = document.revisionID else {
            return "尚未生成共享 revision"
        }
        let time = document.updatedAt?.formatted(date: .abbreviated, time: .shortened) ?? "时间未知"
        return "\(time) · \(revisionID.prefix(10))"
    }
}

private struct LeaseStatusCard: View {
    let lease: DocumentLeaseSnapshot

    var body: some View {
        TCNotice(
            title: lease.isHeldByLocalPeer ? "你持有编辑租约" : "\(lease.holderName) 正在编辑",
            message: lease.isHeldByLocalPeer
                ? "租约将在 \(lease.expiresAt.formattedRelative)到期；离开编辑页会主动释放。"
                : "当前为只读。租约将在 \(lease.expiresAt.formattedRelative)到期，之后可重新申请。",
            systemImage: lease.isHeldByLocalPeer ? "lock.open.fill" : "lock.fill",
            tone: lease.isHeldByLocalPeer ? .success : .warning
        )
    }
}

struct MarkdownPreview: View {
    let content: String

    private var attributedContent: AttributedString {
        (try? AttributedString(markdown: content)) ?? AttributedString(content)
    }

    var body: some View {
        Text(attributedContent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .accessibilityLabel("Trip.md 预览")
            .accessibilityValue(content)
    }
}

