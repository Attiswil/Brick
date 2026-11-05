import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var newTagName = ""
    @State private var addingTag = false

    var body: some View {
        NavigationStack {
            Form {
                RulesSection()
                tagsSection
                homeAssistantSection
                permissionsSection
                Section {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                } footer: {
                    Text("No AI, no accounts, no analytics. Everything runs on this phone; Home Assistant is optional.")
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
                 : "Put a tag somewhere inconvenient - the walk is the point. If Home Assistant is linked, the same tag also works on an ESPHome NFC reader.")
        }
    }

    @ViewBuilder private var homeAssistantSection: some View {
        Section {
            if let conn = model.connection {
                LabeledContent("Server", value: conn.baseURL.host() ?? conn.baseURL.absoluteString)
                LabeledContent("This phone", value: conn.deviceName)
                if let last = model.lastReport {
                    LabeledContent("Last update sent") { Text(last, style: .relative) }
                }
                Button("Send update now") { Task { await model.syncNow() } }
                Button("Unlink", role: .destructive) { Task { await model.disconnect() } }
            } else {
                NavigationLink("Link Home Assistant") { ConnectView() }
            }
        } header: {
            Text("Home Assistant (optional)")
        } footer: {
            Text(model.isConnected
                 ? "Home Assistant automations can brick or unbrick this phone and see its state. The phone still makes every decision, so it works the same when HA is down."
                 : "Link it to let any Home Assistant trigger brick this phone. Not needed for anything else.")
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

/// Rules live on the phone. Locked while bricked.
private struct RulesSection: View {
    @EnvironmentObject private var model: AppModel
    @State private var draft = BrickRules()

    var body: some View {
        Section {
            Toggle("Strict mode", isOn: $draft.strict)
            Stepper("Emergency unbricks: \(draft.emergencyMax)", value: $draft.emergencyMax, in: 0...20)
            Stepper("Reset takes \(Int(draft.resetHours)) hours", value: $draft.resetHours, in: 1...336, step: 1)
            Toggle("Start the reset automatically when I run out", isOn: $draft.autoRequestReset)
            Toggle("Scanning a tag while unbricked bricks me", isOn: $draft.tagToggles)
            if draft != model.rules {
                Button("Save rules") { model.save(rules: draft) }
            }
        } header: {
            Text("Rules")
        } footer: {
            Text(model.state.bricked
                 ? "Rules are locked while you're bricked."
                 : "Strict mode: only a brick tag, a timer, a schedule, a Home Assistant automation or an emergency unbrick can end a brick. Raising the number of emergency unbricks doesn't refill them - only a reset does.")
        }
        .disabled(model.state.bricked)
        .onAppear { draft = model.rules }
        .onChange(of: model.rules) { _, rules in draft = rules }
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
                Text("Install the Brick Hub integration in Home Assistant first. Create a token under your HA profile → Security → Long-lived access tokens. A URL that works away from home (Nabu Casa, Tailscale, a reverse proxy) lets the phone report its state from anywhere.")
            }
            Button {
                Task { if await model.connect(url: url, token: token, deviceName: name) { dismiss() } }
            } label: {
                if model.busy { ProgressView() } else { Text("Link") }
            }
            .disabled(url.isEmpty || token.isEmpty || model.busy)
        }
        .navigationTitle("Home Assistant")
    }
}
