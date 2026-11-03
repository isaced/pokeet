import PokeetCore
import SwiftUI

/// Provider list for Settings → Web Search.
///
/// A `Button` row would only hit-test its drawn content — the gap between the
/// name and the trailing checkmark swallowed taps. An inline `Picker` is the
/// native list-selection control, so the whole row responds, the checkmark is
/// system-drawn and VoiceOver announces "selected" for free.
struct ProviderPicker: View {
    @Binding var selection: WebSearchProviderKind

    var body: some View {
        Picker("Provider", selection: $selection) {
            ForEach(WebSearchProviderKind.allCases) { kind in
                ProviderLabel(kind: kind)
                    .tag(kind)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }
}

private struct ProviderLabel: View {
    let kind: WebSearchProviderKind

    var body: some View {
        HStack(spacing: 12) {
            icon
            Text(kind.displayName)
        }
    }

    private var icon: some View {
        Group {
            if let asset = kind.brandAssetName {
                Image(asset)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: kind.iconName)
                    .font(.system(size: 15, weight: .semibold))
            }
        }
        .foregroundStyle(.white)
        .frame(width: 30, height: 30)
        .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 8))
    }
}
