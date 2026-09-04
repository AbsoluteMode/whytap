import SwiftUI

/// Segmented control mirroring the mockup's `.mac-seg`. Generic over a Hashable value.
struct MacSegmented<Value: Hashable>: View {
    struct Item: Identifiable {
        let value: Value
        let label: String
        var id: Value { value }
    }

    let items: [Item]
    @Binding var selection: Value
    /// Values that are present but non-selectable (rendered dimmed, taps
    /// ignored). Default empty — every segment is enabled.
    var disabledValues: Set<Value> = []

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items) { item in
                let isSel = item.value == selection
                let isDisabled = disabledValues.contains(item.value)
                Button {
                    guard !isDisabled else { return }
                    selection = item.value
                } label: {
                    Text(item.label)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(isSel ? Color.white : MacSettingsTheme.text)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity)
                        .background(
                            isSel ? MacSettingsTheme.segSel : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
                .opacity(isDisabled ? 0.38 : 1)
            }
        }
        .padding(2)
        .background(MacSettingsTheme.segBg, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}
