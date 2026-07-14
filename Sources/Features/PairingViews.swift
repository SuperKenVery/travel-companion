import DeviceDiscoveryUI
import Network
import SwiftUI
import WiFiAware

struct WiFiAwarePairingControls: View {
    let isLabRunning: Bool
    let pairedDeviceNames: [String]
    let dataPublisherState: String
    let voicePublisherState: String
    let discoveryState: String
    let connectionState: String
    let onStartPublishing: () -> Void
    let onEndpointSelected: (WAEndpoint) -> Void

    var body: some View {
        if let publishService, let subscribeService {
            VStack(alignment: .leading, spacing: 18) {
                pairingStep(publishService)
                Divider()
                publishingStep
                Divider()
                discoveryStep(subscribeService)
            }
            .padding(.vertical, 6)
        } else {
            Label("Wi‑Fi Aware 服务声明缺失", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }

    private func pairingStep(_ service: WAPublishableService) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            stepTitle(1, "允许本机被配对")
            DevicePairingView(
                .wifiAware(
                    .connecting(
                        to: service,
                        from: .userSpecifiedDevices
                    )
                ),
                access: .permanent
            ) {
                Label("打开系统配对授权", systemImage: "person.badge.plus")
                    .frame(maxWidth: .infinity)
            } fallback: {
                Label("系统配对界面不可用", systemImage: "exclamationmark.triangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            if pairedDeviceNames.isEmpty {
                Text("尚无已配对设备；在两台设备上完成系统配对后，这里会自动更新。")
                    .foregroundStyle(.secondary)
            } else {
                Text("已配对：\(pairedDeviceNames.joined(separator: "、"))")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var publishingStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            stepTitle(2, "启动服务，允许对端发现")
            Button(action: onStartPublishing) {
                Label("启动数据与语音服务", systemImage: "antenna.radiowaves.left.and.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!isLabRunning)

            LabeledContent("数据服务", value: dataPublisherState)
            LabeledContent("语音服务", value: voicePublisherState)
            if !isLabRunning {
                Text("请先在“总览”开始全部验证。")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func discoveryStep(_ service: WASubscribableService) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            stepTitle(3, "查找并连接另一台设备")
            DevicePicker(
                .wifiAware(
                    .connecting(to: .userSpecifiedDevices, from: service)
                ),
                access: .permanent,
                onSelect: onEndpointSelected,
                label: {
                    Label("打开系统设备查找", systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity)
                },
                fallback: {
                    Label("系统设备查找不可用", systemImage: "exclamationmark.triangle")
                        .frame(maxWidth: .infinity)
                },
                parameters: {
                    NWParameters.tcp
                        .wifiAware { $0.performanceMode = .bulk }
                }
            )
            .buttonStyle(.borderedProminent)
            .disabled(!isLabRunning)

            LabeledContent("查找", value: discoveryState)
            LabeledContent("数据连接", value: connectionState)
            Text("只有主动连接端在此步骤选择 peer；发布端不需要选择。")
                .foregroundStyle(.secondary)
        }
    }

    private func stepTitle(_ number: Int, _ title: String) -> some View {
        Label("\(number). \(title)", systemImage: "\(number).circle.fill")
            .font(.headline)
    }

    private var publishService: WAPublishableService? {
        WAPublishableService.allServices["_tc-validate._tcp"]
    }

    private var subscribeService: WASubscribableService? {
        WASubscribableService.allServices["_tc-validate._tcp"]
    }
}
