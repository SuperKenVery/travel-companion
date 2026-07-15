import SwiftUI

struct GroupPairingControls: View {
    let isLabRunning: Bool
    let groupID: String?
    let createdGroupPIN: String?
    let bleMemberNames: [String]
    let bonjourMemberNames: [String]
    let dataPublisherState: String
    let voicePublisherState: String
    let discoveryState: String
    let connectionState: String
    let pairingError: String?
    let onCreateGroup: () -> Void
    let onJoinGroup: (String) -> Void
    let onLeaveGroup: () -> Void

    @State private var pin = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            bluetoothStep
            Divider()
            pairingStep
            Divider()
            networkStep
        }
        .padding(.vertical, 6)
    }

    private var bluetoothStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            stepTitle(1, "用蓝牙发现附近成员")
            Text(isLabRunning ? "BLE Central 与 Peripheral 已启动，会自动发现并连接附近设备。" : "请先在“总览”开始全部验证。")
                .foregroundStyle(.secondary)
            if bleMemberNames.isEmpty {
                LabeledContent("PIN 已认证成员", value: "暂无")
            } else {
                LabeledContent("PIN 已认证成员", value: bleMemberNames.joined(separator: "、"))
            }
        }
    }

    private var pairingStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            stepTitle(2, "输入一次群组 PIN")
            if let groupID {
                LabeledContent("群组 ID", value: groupID)
                    .font(.caption.monospaced())
                if let createdGroupPIN {
                    LabeledContent("请让同行者输入", value: createdGroupPIN)
                        .font(.title3.monospacedDigit().bold())
                }
                Button("退出当前群组", role: .destructive, action: onLeaveGroup)
            } else {
                Button(action: onCreateGroup) {
                    Label("创建群组并生成 PIN", systemImage: "person.3.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isLabRunning)

                TextField("6 位 PIN", text: $pin)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .onChange(of: pin) { _, value in
                        pin = String(value.filter(\.isNumber).prefix(6))
                    }
                Button("加入群组") {
                    onJoinGroup(pin)
                }
                .buttonStyle(.bordered)
                .disabled(!isLabRunning || pin.count != 6)
            }
            if let pairingError {
                Text(pairingError).font(.caption).foregroundStyle(.red)
            }
            Text("PIN 用于派生本次技术验证的群组密钥；验证成功后只保存派生凭据，不保存 PIN。正式产品应换成 PAKE 或带速率限制的邀请协议。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var networkStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            stepTitle(3, "Bonjour 自动重连")
            LabeledContent("数据服务", value: dataPublisherState)
            LabeledContent("语音服务", value: voicePublisherState)
            LabeledContent("查找", value: discoveryState)
            LabeledContent("数据连接", value: connectionState)
            LabeledContent(
                "Bonjour 同群成员",
                value: bonjourMemberNames.isEmpty ? "暂无" : bonjourMemberNames.joined(separator: "、")
            )
            Text("入群后自动发布和浏览服务；所有 listener、browser 与 connection 都启用 peerToPeerIncluded，允许系统选择 AWDL。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func stepTitle(_ number: Int, _ title: String) -> some View {
        Label("\(number). \(title)", systemImage: "\(number).circle.fill")
            .font(.headline)
    }
}
