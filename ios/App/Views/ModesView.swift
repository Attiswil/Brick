import FamilyControls
import SwiftUI

struct ModesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editing: BrickMode?

    var body: some View {
        NavigationStack {
            List {
                if model.state.bricked { LockedNotice(text: "Modes can't be changed while you're bricked.") }
                ForEach(model.modes) { mode in
                    Button { editing = mode } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(mode.name).font(.headline)
                            Text(mode.summary).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)
                    .disabled(model.state.bricked)
                }
                .onDelete { idx in idx.map { model.modes[$0] }.forEach(model.delete(mode:)) }
                .deleteDisabled(model.state.bricked)
                if model.modes.isEmpty {
                    Text("A mode is a set of apps and websites to block (or the only ones to allow). Modes appear in Home Assistant so automations can pick one.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Modes")
            .toolbar {
                Button { editing = BrickMode(name: "") } label: { Image(systemName: "plus") }
                    .disabled(model.state.bricked)
            }
            .sheet(item: $editing) { mode in
                ModeEditor(mode: mode).environmentObject(model)
            }
        }
    }
}

struct ModeEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var mode: BrickMode
    @State private var picking = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name (e.g. Deep work)", text: $mode.name)
                Section {
                    Picker("Style", selection: $mode.style) {
                        ForEach(BlockStyle.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Button {
                        picking = true
                    } label: {
                        Label(mode.style == .blockList ? "Choose apps & sites to block" : "Choose apps & sites to allow",
                              systemImage: "app.badge.checkmark")
                    }
                    Text(mode.summary).font(.footnote).foregroundStyle(.secondary)
                } footer: {
                    Text(mode.style == .blockList
                         ? "Only what you pick is blocked."
                         : "Everything is blocked except what you pick (plus anything iOS never lets apps block).")
                }
                if !mode.selection.applicationTokens.isEmpty {
                    Section("Apps") {
                        ForEach(Array(mode.selection.applicationTokens), id: \.self) { token in
                            Label(token)
                        }
                    }
                }
                if !mode.selection.categoryTokens.isEmpty {
                    Section("Categories") {
                        ForEach(Array(mode.selection.categoryTokens), id: \.self) { token in
                            Label(token)
                        }
                    }
                }
                Section {
                    Toggle("Prevent deleting apps while bricked", isOn: $mode.preventAppRemoval)
                } footer: {
                    Text("Stops the classic escape of deleting and reinstalling an app (or Brick Hub itself).")
                }
            }
            .navigationTitle(mode.name.isEmpty ? "New mode" : mode.name)
            .navigationBarTitleDisplayMode(.inline)
            .familyActivityPicker(isPresented: $picking, selection: $mode.selection)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if mode.name.trimmingCharacters(in: .whitespaces).isEmpty { mode.name = "Mode \(model.modes.count + 1)" }
                        model.save(mode: mode)
                        dismiss()
                    }
                }
            }
        }
    }
}

struct LockedNotice: View {
    var text: String
    var body: some View {
        Label(text, systemImage: "lock.fill")
            .font(.footnote)
            .foregroundStyle(.orange)
    }
}
