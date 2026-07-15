import SwiftUI

@MainActor
struct ConversationListView: View {
    @Environment(TravelCore.self) private var core

    private var snapshot: AppSnapshot { core.snapshot }
    private var conversations: [ConversationSnapshot] {
        snapshot.conversations.sorted { lhs, rhs in
            let lhsDate = lhs.messages.last?.createdAt ?? .distantPast
            let rhsDate = rhs.messages.last?.createdAt ?? .distantPast
            return lhsDate > rhsDate
        }
    }

    var body: some View {
        Group {
            if snapshot.group == nil {
                TCEmptyState(
                    title: "加入群组后开始聊天",
                    message: "群聊和一对一消息都通过附近设备离线同步。",
                    systemImage: "bubble.left.and.exclamationmark.bubble.right"
                )
            } else if conversations.isEmpty {
                TCEmptyState(
                    title: "还没有会话",
                    message: "发现群组成员后，会在这里建立群聊和私聊入口。",
                    systemImage: "bubble.left.and.bubble.right"
                )
            } else {
                List(conversations) { conversation in
                    NavigationLink {
                        ConversationView(conversationID: conversation.id)
                    } label: {
                        ConversationRow(conversation: conversation)
                    }
                    .accessibilityHint("打开会话")
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("消息")
    }
}

private struct ConversationRow: View {
    let conversation: ConversationSnapshot

    private var latestMessage: MessageSnapshot? { conversation.messages.last }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(conversation.kind.lowercased() == "group" ? Color.blue.opacity(0.14) : Color.purple.opacity(0.14))
                    .frame(width: 48, height: 48)
                Image(systemName: conversation.kind.lowercased() == "group" ? "person.3.fill" : "person.fill")
                    .foregroundStyle(conversation.kind.lowercased() == "group" ? .blue : .purple)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(conversation.title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    if let date = latestMessage?.createdAt {
                        Text(date.formattedRelative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Text(previewText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    if conversation.unreadCount > 0 {
                        Text("\(conversation.unreadCount)")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.tint, in: .capsule)
                            .accessibilityLabel("\(conversation.unreadCount) 条未读消息")
                    }
                }
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }

    private var previewText: String {
        guard let message = latestMessage else { return "暂无消息" }
        let prefix = message.isOutgoing ? "你：" : "\(message.senderName)："
        switch message.kind.lowercased() {
        case "image": return prefix + "[图片]"
        case "voice", "audio": return prefix + "[语音]"
        default: return prefix + (message.text ?? "新消息")
        }
    }
}

