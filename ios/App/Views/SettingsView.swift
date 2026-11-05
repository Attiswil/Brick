import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var newTagName = ""
    @State private var addingTag = false

    var body: some View {
        NavigationStack {
            Form {
                homeAssistantSection
                tagsSection
                rulesSection
                permissionsSection
                Section {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                } footer: {
                    Text("No AI, no accounts, no analytics. Your data stays on your phone and your own Home Assistant.")
                }
            }
            .navigationTitle("Settings")
            .alert("Name this brick", isPresented: $addingTag) {
                TextField("e.g. Desk brick", text: $newTagName)
                Button("Scan") { Task { await model.addTag(name: newTagName); newTagName = "" } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Any NFC sticker, card or key fob works. Next you'll hold it to the top of your iPhone.")
            }
        }
    }

    @ViewBuilder private var homeAssistantSection: some View {
        Section {
            if let conn = model.connection {
                LabeledContent("Server", value: conn.baseURL.host() ?? conn.baseURL.absoluteString)
                LabeledContent("This phone", value: conn.deviceName)
                if let last = model.lastSync {
                    LabeledContent("Last sync") { Text(last, style: .relative) }
                }
                if model.pendingCount > 0 {
                    LabeledContent("Queued offline", value: "\(model.pendingCount)")
                }
                Button("Sync now") { Task { await model.syncNow() } }
                Button("Disconnect", role: .destructive) { Task { await model.disconnect() } }
                    .disabled(model.state.bricked)
            } else {
                NavigationLink("Connect Home Assistant") { ConnectView() }
            }
        } header: {
            Text("Home Assistant")
        } footer: {
            Text(model.isConnected
                 ? "Any Home Assistant trigger can brick this phone. Rules (strict mode, emergency unbricks) are managed in the Brick Hub integration."
                 : "Optional. Without it Brick Hub works standalone with tags, timers and schedules.")
        }
    }

    @ViewBuilder private var tagsSection: some View {
        Section {
            ForEach(model.tags) { tag in
                Label(tag.name, systemImage: "wave.3.right")
            }
            .onDelete { idx in
                let hashes = idx.map { model.tags[$0].hash }
                Task { for h in hashes { await model.removeTag(hash: h) } }
            }
            .deleteDisabled(model.state.bricked)
            Button("Add a brick tag") { addingTag = true }
                .disabled(model.state.bricked)
        } header: {
            Text("Brick tags")
        } footer: {
            Text(model.state.bricked
                 ? "Tags can't be added or removed while bricked."
                 : "Put a tag somewhere inconvenient - the walk is the point. Tags also work with ESPHome NFC readers and the Home Assistant app.")
        }
    }

    @ViewBuilder private var rulesSection: some View {
        Section {
            if model.isConnected {
                LabeledContent("Strict mode", value: model.state.strict ? "On" : "Off")
                LabeledContent("Emergency unbricks", value: "\(model.state.emergencyMax)")
                LabeledContent("Reset takes", value: "\(Int(model.state.resetHours)) hours")
            } else {
                StandaloneRules()
            }
        } header: {
            Text("Rules")
        } footer: {
            Text("Strict mode means only a brick tag, a timer, a schedule or an emergency unbrick can end a brick. Emergency unbricks refill only after a reset, which takes the full delay.")
        }
    }

    @ViewBuilder private var permissionsSection: some View {
        Section("Permissions") {
            LabeledContent("Screen Time", value: model.authorized ? "Allowed" : "Not allowed")
            if !model.authorized {
                Button("Allow Screen Time access") { Task { await model.requestScreenTime() } }
            }
            Button("Enable notifications") { Task { await model.requestNotifications() } }
        }
    }
}

private struct StandaloneRules: View {
    @EnvironmentObject private var model: AppModel
    @State private var strict = true
    @State private var emergencyMax = 5
    @State private var resetHours = 48.0

    var body: some View {
        Group {
            Toggle("Strict mode", isOn: $strict)
            Stepper("Emergency unbricks: \(emergencyMax)", value: $emergencyMax, in: 0...20)
            Stepper("Reset takes \(Int(resetHours)) hours", value: $resetHours, in: 1...336, step: 1)
            Button("Save rules") {
                model.updateStandalone(emergencyMax: emergencyMax, resetHours: resetHours, strict: strict)
            }
        }
        .disabled(model.state.bricked)
        .onAppear {
            strict = model.state.strict
            emergencyMax = model.state.emergencyMax
            resetHours = model.state.resetHours
        }
    }
}

struct ConnectView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var token = ""
    @State private var name = UIDevice.current.name

    var body: some View {
        Form {
            Section {
                TextField("https://homeassistant.local:8123", text: $url)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Long-lived access token", text: $token)
                TextField("Name for this phone", text: $name)
            } footer: {
                Text("Use a URL that works away from home too (e.g. Nabu Casa or your own reverse proxy). Create a token in Home Assistant under your profile → Security → Long-lived access tokens. The Brick Hub integration must be installed first.")
            }
            Button {
                Task { if await model.connect(url: url, token: token, deviceName: name) { dismiss() } }
            } label: {
                if model.busy { ProgressView() } else { Text("Connect") }
            }
            .disabled(url.isEmpty || token.isEmpty || model.busy)
        }
        .navigationTitle("Home Assistant")
    }
}
