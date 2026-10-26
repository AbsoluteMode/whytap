import SwiftUI

struct MeetingAssistantSpaceSelector: View {
    @ObservedObject var model: MeetingAssistantModel
    @State private var hover = false
    var body: some View {
        HStack {
            Text("Beta")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            Menu {
                ForEach(model.spaces) { space in
                    Button { model.selectSpace(space.id) } label: {
                        if model.selectedSpaceID == space.id { Label(space.name, systemImage: "checkmark") }
                        else { Text(space.name) }
                    }
                }
            } label: {
                Text(model.currentSpace?.name ?? "Выбрать проект")
                    .font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    .padding(.horizontal, 6).padding(.vertical, 5)
            }
            .menuStyle(.borderlessButton).menuIndicator(.visible)
            .frame(maxWidth: 205, alignment: .trailing)
            .fixedSize(horizontal: true, vertical: true)
            .background(Color.primary.opacity(hover ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onHover { hover = $0 }
            .accessibilityLabel("Выбрать проект: \(model.currentSpace?.name ?? "не выбран")")
        }
        .padding(.horizontal, 5)
    }
}
