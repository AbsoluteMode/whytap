import SwiftUI

/// Dropdown mirroring the mockup's `.mac-popup` (control button + accent chevron tile).
/// Backed by a native `Menu` so keyboard/VoiceOver behaviour stays correct.
struct MacPopup<Value: Hashable>: View {
    struct Item: Identifiable {
        let value: Value
        let label: String
        var id: Value { value }
    }

    let items: [Item]
    @Binding var selection: Value
    var minWidth: CGFloat = 90

    private var currentLabel: String {
        items.first { $0.value == selection }?.label ?? ""
    }

    var body: some View {
        Menu {
            ForEach(items) { item in
                Button {
                    selection = item.value
                } label: {
                    if item.value == selection {
                        Label(item.label, systemImage: "checkmark")
                    } else {
                        Text(item.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(currentLabel)
                    .font(.system(size: 13))
                    .foregroundStyle(MacSettingsTheme.text)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 20)
                    .background(MacSettingsTheme.accent, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .padding(.leading, 10)
            .padding(.trailing, 4)
            .padding(.vertical, 4)
            .frame(minWidth: minWidth)
            .background(MacSettingsTheme.controlBg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
