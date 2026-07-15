import Observation
import SwiftUI

enum AppTab: String, CaseIterable, Identifiable, Hashable {
    case travel
    case chat
    case places
    case document
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .travel: "同行"
        case .chat: "消息"
        case .places: "地点"
        case .document: "行程"
        case .settings: "设置"
        }
    }

    var systemImage: String {
        switch self {
        case .travel: "location.north.circle"
        case .chat: "bubble.left.and.bubble.right"
        case .places: "mappin.and.ellipse"
        case .document: "doc.text"
        case .settings: "gearshape"
        }
    }
}

enum AppSheetDestination: Identifiable, Equatable {
    case createGroup
    case joinGroup
    case createPlace
    case editPlace(id: String)
    case documentConflict(id: String)
    case camera(conversationID: String)
    case recordVoice(conversationID: String)

    var id: String {
        switch self {
        case .createGroup: "group-create"
        case .joinGroup: "group-join"
        case .createPlace: "place-create"
        case .editPlace(let id): "place-edit-\(id)"
        case .documentConflict(let id): "document-conflict-\(id)"
        case .camera(let conversationID): "camera-\(conversationID)"
        case .recordVoice(let conversationID): "voice-recorder-\(conversationID)"
        }
    }
}

@MainActor
@Observable
final class AppRouter {
    var presentedSheet: AppSheetDestination?

    func present(_ sheet: AppSheetDestination) {
        presentedSheet = sheet
    }
}

@MainActor
struct AppShell: View {
    @Environment(TravelCore.self) private var core

    @State private var selectedTab: AppTab = .travel
    @State private var router = AppRouter()
    @State private var travelPath = NavigationPath()
    @State private var chatPath = NavigationPath()
    @State private var placesPath = NavigationPath()
    @State private var documentPath = NavigationPath()
    @State private var settingsPath = NavigationPath()

    var body: some View {
        Group {
            if core.isBootstrapped {
                appTabs
            } else if let error = core.lastError {
                TCEmptyState(
                    title: "无法启动旅行核心",
                    message: error.message,
                    systemImage: "exclamationmark.icloud",
                    actionTitle: "重试"
                ) {
                    Task { await core.bootstrap() }
                }
            } else {
                VStack(spacing: 14) {
                    ProgressView()
                        .controlSize(.large)
                    Text("正在打开本地旅行数据…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .tcPageBackground()
                .accessibilityElement(children: .combine)
                .accessibilityLabel("正在打开本地旅行数据")
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 6) {
                if let call = core.snapshot.activeCall {
                    ActiveCallBanner(call: call)
                }
                if core.isBootstrapped, let error = core.lastError {
                    TCNotice(
                        title: "操作失败",
                        message: error.message,
                        systemImage: "exclamationmark.triangle.fill",
                        tone: .danger
                    )
                }
            }
            .padding(.horizontal, TCDesign.pagePadding)
            .padding(.top, 6)
        }
        .sheet(
            item: Binding(
                get: { router.presentedSheet },
                set: { router.presentedSheet = $0 }
            )
        ) { destination in
            NavigationStack {
                switch destination {
                case .createGroup:
                    CreateGroupSheet()
                case .joinGroup:
                    JoinGroupSheet()
                case .createPlace:
                    PlaceEditorSheet(placeID: nil)
                case .editPlace(let id):
                    PlaceEditorSheet(placeID: id)
                case .documentConflict(let id):
                    DocumentConflictSheet(conflictID: id)
                case .camera(let conversationID):
                    CameraCaptureSheet(conversationID: conversationID)
                case .recordVoice(let conversationID):
                    VoiceRecorderSheet(conversationID: conversationID)
                }
            }
        }
        .environment(router)
    }

    private var appTabs: some View {
        TabView(selection: $selectedTab) {
            Tab(AppTab.travel.title, systemImage: AppTab.travel.systemImage, value: AppTab.travel) {
                NavigationStack(path: $travelPath) {
                    TravelOverviewView()
                }
            }

            Tab(AppTab.chat.title, systemImage: AppTab.chat.systemImage, value: AppTab.chat) {
                NavigationStack(path: $chatPath) {
                    ConversationListView()
                }
            }

            Tab(AppTab.places.title, systemImage: AppTab.places.systemImage, value: AppTab.places) {
                NavigationStack(path: $placesPath) {
                    PlaceListView()
                }
            }

            Tab(AppTab.document.title, systemImage: AppTab.document.systemImage, value: AppTab.document) {
                NavigationStack(path: $documentPath) {
                    DocumentView()
                }
            }

            Tab(AppTab.settings.title, systemImage: AppTab.settings.systemImage, value: AppTab.settings) {
                NavigationStack(path: $settingsPath) {
                    SettingsView()
                }
            }
        }
    }
}

private struct ActiveCallBanner: View {
    @Environment(TravelCore.self) private var core

    let call: CallSnapshot

    private var isIncomingOffer: Bool {
        let direction = call.direction.lowercased()
        let state = call.state.lowercased()
        return direction == "incoming" && ["offered", "ringing", "incoming"].contains(state)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "phone.fill")
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(.green, in: .circle)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(call.peerName)
                    .font(.headline)
                    .lineLimit(1)
                Text(isIncomingOffer ? "离线来电" : callStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if isIncomingOffer {
                Button {
                    Task { await core.send(.rejectCall(callID: call.id)) }
                } label: {
                    Image(systemName: "phone.down.fill")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .accessibilityLabel("拒绝 \(call.peerName) 的来电")

                Button {
                    Task { await core.send(.answerCall(callID: call.id)) }
                } label: {
                    Image(systemName: "phone.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .accessibilityLabel("接听 \(call.peerName) 的来电")
            } else {
                Button("结束") {
                    Task { await core.send(.endCall(callID: call.id)) }
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .accessibilityLabel("结束与 \(call.peerName) 的通话")
            }
        }
        .padding(12)
        .background(.regularMaterial, in: .rect(cornerRadius: TCDesign.cardRadius))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
        .accessibilityElement(children: .contain)
    }

    private var callStatus: String {
        switch call.state.lowercased() {
        case "connecting": "正在连接"
        case "connected", "active": "通话中"
        case "reconnecting": "正在重新连接"
        default: call.state
        }
    }
}
