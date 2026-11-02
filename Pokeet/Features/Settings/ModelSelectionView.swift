import PokeetCore
import SwiftUI

struct ModelSelectionView: View {
    @Binding var draft: ProviderConfiguration
    let apiKey: String

    @State private var filter = ""
    @State private var isFetching = false
    @State private var fetchMessage: String?
    @State private var errorMessage: String?
    @State private var newModelID = ""
    @State private var isAddingModel = false

    private var filteredModels: [ProviderModel] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return draft.models }
        return draft.models.filter {
            $0.id.lowercased().contains(query)
                || $0.label.lowercased().contains(query)
        }
    }

    var body: some View {
        List {
            Section {
                Button {
                    Task { await fetchModels() }
                } label: {
                    HStack(spacing: 8) {
                        if isFetching {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(isFetching ? "Fetching models…" : "Fetch models from provider")
                    }
                }
                .disabled(isFetching)

                if let fetchMessage {
                    Text(fetchMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section {
                if filteredModels.isEmpty {
                    Text(filter.isEmpty ? "No models yet." : "No matching models.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filteredModels) { model in
                        modelRow(model)
                            .swipeActions {
                                Button(role: .destructive) {
                                    remove(model)
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                    }
                }
            } header: {
                HStack {
                    Text("\(draft.selectedModelIDs.count) selected")
                    Spacer()
                    Text("\(draft.models.count) available")
                }
            } footer: {
                Text("Tap a model to include or exclude it. Tap the star to make it the default chat model.")
            }
        }
        .searchable(
            text: $filter,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Filter models"
        )
        .navigationTitle("Models")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button {
                        selectAll()
                    } label: {
                        Label("Select all", systemImage: "checkmark.circle")
                    }
                    Button {
                        deselectAll()
                    } label: {
                        Label("Deselect all", systemImage: "circle")
                    }
                    Divider()
                    Button {
                        isAddingModel = true
                    } label: {
                        Label("Add model ID", systemImage: "plus")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert("Add model ID", isPresented: $isAddingModel) {
            TextField("Model ID", text: $newModelID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Add") {
                _ = draft.addCustomModel(id: newModelID)
                newModelID = ""
            }
            Button("Cancel", role: .cancel) {
                newModelID = ""
            }
        } message: {
            Text("Use the exact model ID accepted by this provider.")
        }
    }

    private func modelRow(_ model: ProviderModel) -> some View {
        HStack(spacing: 12) {
            Button {
                toggle(model)
            } label: {
                Image(
                    systemName: draft.selectedModelIDs.contains(model.id)
                        ? "checkmark.circle.fill"
                        : "circle"
                )
                .font(.system(size: 20))
                .foregroundStyle(
                    draft.selectedModelIDs.contains(model.id) ? Color.accentColor : .secondary
                )
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.label)
                    .font(.subheadline)
                if model.label != model.id {
                    Text(model.id)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    if let context = model.contextWindow {
                        Text(contextLabel(context))
                    }
                    if model.isCustom {
                        Text("CUSTOM")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button {
                select(model)
                draft.defaultModelID = model.id
            } label: {
                Image(
                    systemName: draft.defaultModelID == model.id ? "star.fill" : "star"
                )
                .foregroundStyle(
                    draft.defaultModelID == model.id ? Color.orange : .secondary
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Make \(model.label) the default model")
        }
        .contentShape(Rectangle())
        .onTapGesture {
            toggle(model)
        }
    }

    private func toggle(_ model: ProviderModel) {
        if let index = draft.selectedModelIDs.firstIndex(of: model.id) {
            draft.selectedModelIDs.remove(at: index)
            if draft.defaultModelID == model.id {
                draft.defaultModelID = draft.selectedModelIDs.first ?? ""
            }
        } else {
            draft.selectedModelIDs.append(model.id)
            if draft.defaultModelID.isEmpty {
                draft.defaultModelID = model.id
            }
        }
    }

    private func select(_ model: ProviderModel) {
        guard !draft.selectedModelIDs.contains(model.id) else { return }
        draft.selectedModelIDs.append(model.id)
    }

    private func remove(_ model: ProviderModel) {
        draft.models.removeAll { $0.id == model.id }
        draft.selectedModelIDs.removeAll { $0 == model.id }
        if draft.defaultModelID == model.id {
            draft.defaultModelID = draft.selectedModelIDs.first ?? ""
        }
    }

    private func selectAll() {
        draft.selectedModelIDs = draft.models.map(\.id)
        if draft.defaultModelID.isEmpty {
            draft.defaultModelID = draft.selectedModelIDs.first ?? ""
        }
    }

    private func deselectAll() {
        draft.selectedModelIDs = []
        draft.defaultModelID = ""
    }

    private func fetchModels() async {
        guard !isFetching else { return }
        isFetching = true
        errorMessage = nil
        fetchMessage = nil
        defer { isFetching = false }

        do {
            let models = try await ModelListClient.fetchModels(
                provider: draft,
                apiKey: apiKey
            )
            guard !models.isEmpty else {
                fetchMessage = "The provider returned no models. Add an ID manually."
                return
            }

            draft.mergeModels(models)
            fetchMessage = "Fetched \(models.count) models."
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    private func contextLabel(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return "\(value / 1_000)K"
        }
        return "\(value)"
    }
}
