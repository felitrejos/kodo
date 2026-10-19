import SwiftUI

struct RenameGroupForm: View {
    let rename: (String) -> Void

    @State private var name: String
    @FocusState private var isFocused: Bool

    init(name: String, rename: @escaping (String) -> Void) {
        self.rename = rename
        _name = State(initialValue: name)
    }

    var body: some View {
        HStack(spacing: 8) {
            TextField("Group name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                .focused($isFocused)
                .onSubmit(save)
            Button("Save", action: save)
                .buttonStyle(.glassProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(12)
        .onAppear(perform: focus)
    }

    private func save() {
        rename(name)
    }

    private func focus() {
        isFocused = true
    }
}
