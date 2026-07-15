import SwiftUI

@MainActor
struct PlaceEditorSheet: View {
    @Environment(TravelCore.self) private var core
    @Environment(\.dismiss) private var dismiss

    let placeID: String?

    @State private var title = ""
    @State private var note = ""
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var isSubmitting = false
    @State private var didLoad = false
    @State private var submissionError: String?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case title
        case latitude
        case longitude
    }

    private var existingPlace: PlaceSnapshot? {
        guard let placeID else { return nil }
        return core.snapshot.places.first { $0.id == placeID }
    }

    private var parsedLatitude: Double? { parseCoordinate(latitude) }
    private var parsedLongitude: Double? { parseCoordinate(longitude) }

    private var isValid: Bool {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty,
              let parsedLatitude,
              let parsedLongitude
        else { return false }
        return (-90...90).contains(parsedLatitude) && (-180...180).contains(parsedLongitude)
    }

    var body: some View {
        Form {
            Section("地点") {
                TextField("标题", text: $title)
                    .focused($focusedField, equals: .title)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .latitude }

                TextField("备注（可选）", text: $note, axis: .vertical)
                    .lineLimit(2...6)
            }

            Section {
                TextField("纬度（-90…90）", text: $latitude)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .focused($focusedField, equals: .latitude)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .longitude }

                TextField("经度（-180…180）", text: $longitude)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .focused($focusedField, equals: .longitude)
                    .submitLabel(.done)
                    .onSubmit(save)
            } header: {
                Text("坐标")
            } footer: {
                Text("坐标、标题和备注可完全离线使用。地图底图仅作为系统可用时的增强。")
            }

            if !latitude.isEmpty && parsedLatitude.map({ !(-90...90).contains($0) }) == true {
                Label("纬度必须在 -90 到 90 之间", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            if !longitude.isEmpty && parsedLongitude.map({ !(-180...180).contains($0) }) == true {
                Label("经度必须在 -180 到 180 之间", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }

            if let submissionError {
                Label(submissionError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
        .navigationTitle(placeID == nil ? "添加地点" : "编辑地点")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isSubmitting ? "保存中…" : "保存", action: save)
                    .disabled(!isValid || isSubmitting)
            }
        }
        .onAppear(perform: loadExistingPlace)
        .interactiveDismissDisabled(isSubmitting)
    }

    private func loadExistingPlace() {
        guard !didLoad else { return }
        didLoad = true
        if let place = existingPlace {
            title = place.title
            note = place.note
            latitude = place.latitude.formatted(.number.precision(.fractionLength(0...8)).locale(Locale(identifier: "en_US_POSIX")))
            longitude = place.longitude.formatted(.number.precision(.fractionLength(0...8)).locale(Locale(identifier: "en_US_POSIX")))
        }
        focusedField = .title
    }

    private func save() {
        guard isValid,
              let parsedLatitude,
              let parsedLongitude,
              !isSubmitting
        else { return }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let command: CoreCommand
        if let placeID {
            command = .updatePlace(
                id: placeID,
                title: trimmedTitle,
                note: trimmedNote,
                latitude: parsedLatitude,
                longitude: parsedLongitude
            )
        } else {
            command = .createPlace(
                title: trimmedTitle,
                note: trimmedNote,
                latitude: parsedLatitude,
                longitude: parsedLongitude
            )
        }

        isSubmitting = true
        submissionError = nil
        Task {
            await core.send(command)
            isSubmitting = false
            if let error = core.lastError {
                submissionError = error.message
            } else {
                dismiss()
            }
        }
    }

    private func parseCoordinate(_ value: String) -> Double? {
        Double(value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "."))
    }
}
