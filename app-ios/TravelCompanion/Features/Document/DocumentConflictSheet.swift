import SwiftUI

@MainActor
struct DocumentConflictSheet: View {
    @Environment(TravelCore.self) private var core
    @Environment(\.dismiss) private var dismiss

    let conflictID: String
    @State private var selectedVersion: Version = .conflict

    private enum Version: String, CaseIterable, Identifiable {
        case current = "当前版本"
        case conflict = "冲突副本"
        var id: Self { self }
    }

    private var conflict: DocumentConflictSnapshot? {
        core.snapshot.document.conflicts.first { $0.id == conflictID }
    }

    var body: some View {
        Group {
            if let conflict {
                VStack(spacing: 0) {
                    Picker("文档版本", selection: $selectedVersion) {
                        ForEach(Version.allCases) { version in
                            Text(version.rawValue).tag(version)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding()

                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if selectedVersion == .conflict {
                                TCNotice(
                                    title: "\(conflict.authorName) 的副本",
                                    message: "创建于 \(conflict.createdAt.formatted(date: .abbreviated, time: .shortened)) · Revision \(conflict.revisionID.prefix(10))",
                                    systemImage: "arrow.triangle.branch",
                                    tone: .warning
                                )
                            }

                            Text(selectedContent)
                                .font(.body.monospaced())
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .padding()
                                .background(TCDesign.cardBackground, in: .rect(cornerRadius: TCDesign.compactRadius))
                        }
                        .padding(.horizontal)
                        .padding(.bottom)
                    }
                    .tcPageBackground()
                }
            } else {
                TCEmptyState(
                    title: "冲突副本已处理",
                    message: "同步状态发生变化，这份副本已不在冲突列表中。",
                    systemImage: "checkmark.doc"
                )
            }
        }
        .navigationTitle("比较 Trip.md")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }
            }
        }
    }

    private var selectedContent: String {
        switch selectedVersion {
        case .current: core.snapshot.document.content
        case .conflict: conflict?.content ?? ""
        }
    }
}

