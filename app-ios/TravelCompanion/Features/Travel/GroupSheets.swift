import SwiftUI

@MainActor
struct CreateGroupSheet: View {
    @Environment(TravelCore.self) private var core
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var isSubmitting = false
    @State private var submissionError: String?
    @FocusState private var isNameFocused: Bool

    var body: some View {
        Form {
            Section {
                TextField("例如：川西自驾", text: $name)
                    .textInputAutocapitalization(.words)
                    .focused($isNameFocused)
                    .submitLabel(.done)
                    .onSubmit(create)
            } header: {
                Text("旅行群组")
            } footer: {
                Text("创建后会生成面对面入群 PIN。群组消息、位置和行程只在成员设备间同步。")
            }

            if let submissionError {
                Section {
                    Label(submissionError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("创建群组")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isSubmitting ? "创建中…" : "创建", action: create)
                    .disabled(trimmedName.isEmpty || isSubmitting)
            }
        }
        .onAppear { isNameFocused = true }
        .interactiveDismissDisabled(isSubmitting)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func create() {
        guard !trimmedName.isEmpty, !isSubmitting else { return }
        isSubmitting = true
        submissionError = nil
        Task {
            await core.send(.createGroup(name: trimmedName))
            isSubmitting = false
            if let error = core.lastError {
                submissionError = error.message
            } else {
                dismiss()
            }
        }
    }
}

@MainActor
struct JoinGroupSheet: View {
    @Environment(TravelCore.self) private var core
    @Environment(\.dismiss) private var dismiss

    @State private var pin = ""
    @State private var isSubmitting = false
    @State private var submissionError: String?
    @FocusState private var isPINFocused: Bool

    var body: some View {
        Form {
            Section {
                TextField("PIN", text: $pin)
                    .font(.title2.monospaced())
                    .keyboardType(.asciiCapableNumberPad)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .focused($isPINFocused)
                    .onChange(of: pin) { _, newValue in
                        pin = String(newValue.filter { $0.isLetter || $0.isNumber }.prefix(12)).uppercased()
                    }
            } header: {
                Text("面对面入群")
            } footer: {
                Text("请靠近群主设备并保持两台 iPhone 的蓝牙开启。最多等待 30 秒；找不到群组或握手失败时会在这里提示。")
            }

            if let submissionError {
                Section {
                    Label(submissionError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("加入群组")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isSubmitting ? "加入中…" : "加入", action: join)
                    .disabled(pin.count < 4 || isSubmitting)
            }
        }
        .onAppear { isPINFocused = true }
        .interactiveDismissDisabled(isSubmitting)
    }

    private func join() {
        guard pin.count >= 4, !isSubmitting else { return }
        isSubmitting = true
        submissionError = nil
        Task {
            let error = await core.joinGroup(pin: pin)
            isSubmitting = false
            if let error {
                submissionError = error.message
            } else {
                dismiss()
            }
        }
    }
}
