import SwiftUI

struct SchedulesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editing: BrickSchedule?

    var body: some View {
        NavigationStack {
            List {
                if model.state.bricked { LockedNotice(text: "Schedules can't be changed while you're bricked.") }
                Section {
                    ForEach(model.schedules) { s in
                        Button { editing = s } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(s.name).font(.headline)
                                    Text("\(s.timeLabel) · \(weekdayLabel(s.weekdays))")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                    if let m = model.modes.first(where: { $0.id == s.modeId }) {
                                        Text(m.name).font(.caption).foregroundStyle(.tertiary)
                                    }
                                }
                                Spacer()
                                if !s.enabled { Text("Off").foregroundStyle(.secondary) }
                            }
                        }
                        .foregroundStyle(.primary)
                        .disabled(model.state.bricked)
                    }
                    .onDelete { idx in idx.map { model.schedules[$0] }.forEach(model.delete(schedule:)) }
                    .deleteDisabled(model.state.bricked)
                } footer: {
                    Text("Schedules run on the phone itself, so they work with no signal. For anything smarter - sunset, leaving home, the TV turning on - use a Home Assistant automation instead.")
                }
            }
            .navigationTitle("Schedules")
            .toolbar {
                Button {
                    editing = BrickSchedule(name: "Bedtime", modeId: model.modes.first?.id)
                } label: { Image(systemName: "plus") }
                .disabled(model.state.bricked)
            }
            .sheet(item: $editing) { s in
                ScheduleEditor(schedule: s).environmentObject(model)
            }
        }
    }
}

func weekdayLabel(_ days: Set<Int>) -> String {
    if days.count == 7 { return "Every day" }
    if days == Set(2...6) { return "Weekdays" }
    if days == [1, 7] { return "Weekends" }
    let symbols = Calendar.current.shortWeekdaySymbols
    return days.sorted().map { symbols[$0 - 1] }.joined(separator: " ")
}

struct ScheduleEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var schedule: BrickSchedule

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $schedule.name)
                Toggle("Enabled", isOn: $schedule.enabled)
                Picker("Mode", selection: $schedule.modeId) {
                    ForEach(model.modes) { Text($0.name).tag(Optional($0.id)) }
                }
                Section("Time") {
                    DatePicker("Brick at", selection: minutesBinding(\.startMinutes), displayedComponents: .hourAndMinute)
                    DatePicker("Unbrick at", selection: minutesBinding(\.endMinutes), displayedComponents: .hourAndMinute)
                    if schedule.endMinutes <= schedule.startMinutes {
                        Text("Runs overnight, ending the next day.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("Days") {
                    let symbols = Calendar.current.weekdaySymbols
                    ForEach(1...7, id: \.self) { day in
                        Toggle(symbols[day - 1], isOn: Binding(
                            get: { schedule.weekdays.contains(day) },
                            set: { on in if on { schedule.weekdays.insert(day) } else { schedule.weekdays.remove(day) } }
                        ))
                    }
                }
            }
            .navigationTitle(schedule.name.isEmpty ? "Schedule" : schedule.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { model.save(schedule: schedule); dismiss() }
                        .disabled(schedule.startMinutes == schedule.endMinutes)
                }
            }
        }
    }

    private func minutesBinding(_ key: WritableKeyPath<BrickSchedule, Int>) -> Binding<Date> {
        Binding(
            get: {
                let m = schedule[keyPath: key]
                return Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                schedule[keyPath: key] = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            }
        )
    }
}
