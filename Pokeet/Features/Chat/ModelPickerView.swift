import PokeetCore
import SwiftUI

struct ModelPickerView: View {
    var onSelect: ((ProviderConfiguration, ProviderModel) -> Void)?

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var providerFilter: UUID?

    private struct ModelOption: Identifiable {
        let provider: ProviderConfiguration
        let model: ProviderModel

        var id: String {
            "\(provider.id.uuidString)-\(model.id)"
        }
    }

    private var allOptions: [ModelOption] {
        environment.settings.enabledProviders
            .flatMap { provider in
                provider.selectedModels.map {
                    ModelOption(provider: provider, model: $0)
                }
            }
            .sorted {
                if $0.provider.name != $1.provider.name {
                    return $0.provider.name.localizedStandardCompare($1.provider.name)
                        == .orderedAscending
                }
                return $0.model.label.localizedStandardCompare($1.model.label)
                    == .orderedAscending
            }
    }

    private var filteredOptions: [ModelOption] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return allOptions.filter { option in
            if let providerFilter, option.provider.id != providerFilter {
                return false
            }
            guard !value.isEmpty else { return true }
            return option.model.id.lowercased().contains(value)
                || option.model.label.lowercased().contains(value)
                || option.provider.name.lowercased().contains(value)
        }
    }

    private var filterTitle: String {
        if let providerFilter,
           let provider = environment.settings.provider(id: providerFilter) {
            return provider.name
        }
        return "All"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)

            searchField
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 10)

            if filteredOptions.isEmpty {
                ContentUnavailableView(
                    "No models",
                    systemImage: "cpu",
                    description: Text(
                        environment.settings.enabledProviders.isEmpty
                            ? "Add a provider in Settings first."
                            : "Select models for a provider in Settings → Providers."
                    )
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredOptions) { option in
                            optionRow(option)
                            Divider()
                                .padding(.leading, 58)
                        }
                    }
                    .padding(.bottom, 24)
                }
            }
        }
        .background(Color(.systemGroupedBackground))
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        ZStack {
            Text("Model")
                .font(.headline)

            HStack {
                Button("Cancel") {
                    dismiss()
                }

                Spacer()

                Menu {
                    Button {
                        providerFilter = nil
                    } label: {
                        Label("All providers", systemImage: "square.stack.3d.up")
                    }

                    Divider()

                    ForEach(environment.settings.enabledProviders) { provider in
                        Button {
                            providerFilter = provider.id
                        } label: {
                            Label(provider.name, systemImage: provider.iconName)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(filterTitle)
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                    }
                    .font(.subheadline.weight(.medium))
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Color(.secondarySystemGroupedBackground), in: Capsule())
    }

    private func optionRow(_ option: ModelOption) -> some View {
        Button {
            select(option)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: option.provider.iconName)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(option.model.label)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(option.provider.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                if isSelected(option) {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func isSelected(_ option: ModelOption) -> Bool {
        environment.settings.activeProviderID == option.provider.id
            && option.provider.effectiveModelID == option.model.id
    }

    private func select(_ option: ModelOption) {
        environment.settings.setActiveProvider(option.provider.id)
        environment.settings.setDefaultModel(option.model.id, for: option.provider.id)
        onSelect?(option.provider, option.model)
        dismiss()
    }
}
