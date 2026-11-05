import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var modeId: String?
    @State private var minutes: Double? = nil
    @State private var confirmEmergency = false

    private struct DurationOption: Identifiable {
        var label: String
        var minutes: Double?
        var id: String { label }
    }

    private let durations = [
        DurationOption(label: "No limit", minutes: nil), DurationOption(label: "30m", minutes: 30),
        DurationOption(label: "1h", minutes: 60), DurationOption(label: "2h", minutes: 120),
        DurationOption(label: "4h", minutes: 240), DurationOption(label: "8h", minutes: 480),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    StatusCard(state: model.state, strict: model.rules.strict,
                               modeName: model.modeName(model.state.modeId))
                    if model.state.bricked { brickedActions } else { unbrickedActions }
                    EmergencyCard(confirm: $confirmEmergency)
                    StatsCard(stats: model.stats)
                    ConnectionFooter()
                }
                .padding()
            }
            .navigationTitle("Brick Hub")
            .refreshable { await model.syncNow() }
            .confirmationDialog("Use an emergency unbrick?", isPresented: $confirmEmergency, titleVisibility: .visible) {
                Button("Use emergency unbrick", role: .destructive) { Task { await model.emergencyUnbrick() } }
            } message: {
                Text("You have \(model.state.emergencyRemaining) left. Once they're gone, a reset takes \(Int(model.rules.resetHours)) hours.")
            }
            .onAppear { if modeId == nil { modeId = model.state.modeId ?? model.modes.first?.id } }
        }
    }

    @ViewBuilder private var brickedActions: some View {
        VStack(spacing: 10) {
            ActionButton(title: "Tap brick to unbrick", systemImage: "wave.3.right") {
                await model.scanBrick()
            }
            if !model.rules.strict {
                ActionButton(title: "Unbrick", systemImage: "lock.open", prominent: false) {
                    await model.unbrickWithoutTag()
                }
            }
        }
    }

    @ViewBuilder private var unbrickedActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.modes.isEmpty {
                Label("Create a mode first so Brick Hub knows what to block. Without one, everything is blocked.",
                      systemImage: "info.circle")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Picker("Mode", selection: $modeId) {
                    ForEach(model.modes) { Text($0.name).tag(Optional($0.id)) }
                }
                .pickerStyle(.menu)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(durations) { option in
                        Button(option.label) { minutes = option.minutes }
                            .buttonStyle(.bordered)
                            .tint(minutes == option.minutes ? .orange : .secondary)
                    }
                }
            }
            ActionButton(title: "Tap brick to brick", systemImage: "wave.3.right") {
                await model.scanBrick(modeId: modeId, minutes: minutes)
            }
            ActionButton(title: "Brick now", systemImage: "lock", prominent: false) {
                await model.brickNow(modeId: modeId, minutes: minutes)
            }
        }
    }
}

struct StatusCard: View {
    var state: BrickState
    var strict: Bool
    var modeName: String?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: state.bricked ? "lock.fill" : "lock.open.fill")
                .font(.system(size: 54, weight: .bold))
                .foregroundStyle(state.bricked ? .orange : .green)
                .contentTransition(.symbolEffect(.replace))
                .padding(.top, 8)
            Text(state.bricked ? "Bricked" : "Unbricked")
                .font(.largeTitle.bold())
            if state.bricked {
                if let modeName { Text(modeName).font(.headline) }
                if let since = state.brickedSince {
                    HStack(spacing: 4) {
                        Text("for")
                        Text(since, style: .timer).monospacedDigit()
                    }
                    .foregroundStyle(.secondary)
                }
                if let end = state.endsAt {
                    Text("Unbricks \(end.formatted(date: .omitted, time: .shortened))")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if let source = state.source {
                    Text("By \(source)").font(.footnote).foregroundStyle(.tertiary)
                }
                if strict {
                    Label("Strict mode", systemImage: "shield.lefthalf.filled")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
    }
}

struct EmergencyCard: View {
    @EnvironmentObject private var model: AppModel
    @Binding var confirm: Bool

    var body: some View {
        let s = model.state
        let maxCount = model.rules.emergencyMax
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Emergency unbricks", systemImage: "lifepreserver")
                    .font(.headline)
                Spacer()
                Text("\(s.emergencyRemaining) of \(maxCount)")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(s.emergencyRemaining == 0 ? .red : .primary)
            }
            if s.bricked && s.emergencyRemaining > 0 {
                Button("Use emergency unbrick", role: .destructive) { confirm = true }
                    .buttonStyle(.bordered)
                    .disabled(model.busy)
            }
            if let resetAt = s.emergencyResetAt {
                HStack {
                    Image(systemName: "timer")
                    Text("Refills \(resetAt, style: .relative) from now")
                    Spacer()
                    Button("Cancel") { Task { await model.cancelReset() } }
                        .font(.footnote)
                }
                .font(.subheadline)
                Text(resetAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            } else if s.emergencyRemaining < maxCount {
                Button("Request reset (takes \(Int(model.rules.resetHours)) hours)") {
                    Task { await model.requestReset() }
                }
                .font(.subheadline)
                .disabled(model.busy)
            }
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}

struct StatsCard: View {
    var stats: BrickStats

    var body: some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                tile("Today", formatDuration(stats.todaySeconds), "sun.max")
                tile("Last 7 days", formatDuration(stats.weekSeconds), "calendar")
            }
            GridRow {
                tile("Streak", "\(stats.streakDays) day\(stats.streakDays == 1 ? "" : "s")", "flame")
                tile("Longest", formatDuration(stats.longestSessionSeconds), "trophy")
            }
        }
    }

    private func tile(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.bold().monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct ConnectionFooter: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if model.isConnected {
            HStack(spacing: 6) {
                Circle().fill(model.haReachable == false ? Color.orange : Color.green).frame(width: 8, height: 8)
                Text(model.haReachable == false
                     ? "Home Assistant unreachable - everything still works on this phone"
                     : "Home Assistant can trigger this phone")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
        }
    }
}
