import SwiftUI

/// The group picker under Speaker Sync: switch groups, start a new one, rename or delete.
struct GroupMenu: View {
    let model: KodoModel

    @State private var isRenaming = false

    var body: some View {
        Menu {
            Picker("Group", selection: Binding(get: { model.group.id }, set: { model.selectGroup($0) })) {
                ForEach(model.groups) { group in
                    Text(group.name)
                        .tag(group.id)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Button("New Group", systemImage: "plus", action: addGroup)
            Button("Rename…", systemImage: "pencil", action: startRenaming)
            Button("Delete \(model.group.name)", systemImage: "trash", role: .destructive, action: deleteGroup)
                .disabled(model.groups.count < 2)
        } label: {
            HStack(spacing: 2) {
                Text(model.group.name)
                Image(systemName: "chevron.down")
                    .imageScale(.small)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel("Speaker group: \(model.group.name)")
        .menuIndicator(.hidden)
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .font(.caption.bold())
        .foregroundStyle(.secondary)
        .help("Switch between saved groups of speakers")
        .popover(isPresented: $isRenaming, arrowEdge: .bottom) {
            RenameGroupForm(name: model.group.name, rename: rename)
        }
    }

    private func addGroup() {
        withAnimation(Design.animation) {
            model.addGroup()
        }
        isRenaming = true
    }

    private func startRenaming() {
        isRenaming = true
    }

    private func deleteGroup() {
        withAnimation(Design.animation) {
            model.deleteGroup()
        }
    }

    private func rename(_ name: String) {
        model.renameGroup(to: name)
        isRenaming = false
    }
}
