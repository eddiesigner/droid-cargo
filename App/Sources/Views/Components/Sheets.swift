import CargoServices
import SwiftUI

/// Single text field sheet for "New Folder" and "Rename".
struct NameSheet: View {
    let title: LocalizedStringKey
    let actionTitle: LocalizedStringKey
    let initialName: String
    let commit: (String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var error: String?
    @State private var isWorking = false
    @FocusState private var isFocused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isValid: Bool { !trimmed.isEmpty && !trimmed.contains("/") }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit(submit)
            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(actionTitle, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid || isWorking)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear {
            name = initialName
            isFocused = true
        }
    }

    private func submit() {
        guard isValid else {
            return
        }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await commit(trimmed)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct ConflictSheet: View {
    let prompt: ConflictPrompt
    @State private var applyToAll = false

    private var scope: ConflictScope { applyToAll ? .allRemaining : .thisItem }

    private var location: String {
        prompt.conflict.direction == .toMac ? String(localized: "this Mac") : String(localized: "the phone")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "doc.on.doc")
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("“\(prompt.conflict.name)” already exists")
                        .font(.headline)
                    Text("An item with this name is already on \(location). Do you want to replace it?")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Toggle("Apply to all remaining items", isOn: $applyToAll)
            HStack {
                Button("Skip") { prompt.respond(.skip, scope) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Keep Both") { prompt.respond(.keepBoth, scope) }
                Button("Replace") { prompt.respond(.replace, scope) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .interactiveDismissDisabled()
    }
}
