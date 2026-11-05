import FamilyControls
import Foundation

enum BlockStyle: String, Codable, CaseIterable, Identifiable {
    case blockList, allowList
    var id: String { rawValue }
    var label: String { self == .blockList ? "Block selected" : "Allow only selected" }
}

/// A mode: which apps and sites to block. Apple only exposes the selection as
/// opaque tokens on this device, so modes live here; Home Assistant only
/// sees their ids and names.
struct BrickMode: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var selection = FamilyActivitySelection()
    var style: BlockStyle = .blockList
    var preventAppRemoval = true

    var summary: String {
        let apps = selection.applicationTokens.count
        let cats = selection.categoryTokens.count
        let webs = selection.webDomainTokens.count
        var parts: [String] = []
        if apps > 0 { parts.append("\(apps) app\(apps == 1 ? "" : "s")") }
        if cats > 0 { parts.append("\(cats) categor\(cats == 1 ? "y" : "ies")") }
        if webs > 0 { parts.append("\(webs) site\(webs == 1 ? "" : "s")") }
        let what = parts.isEmpty ? "nothing selected" : parts.joined(separator: ", ")
        return style == .blockList ? "Blocks \(what)" : "Allows only \(what)"
    }
}

/// An on-device schedule. Runs even with no network (via DeviceActivity).
struct BrickSchedule: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var modeId: String?
    var startMinutes = 22 * 60
    var endMinutes = 7 * 60
    /// Calendar weekdays, 1 = Sunday ... 7 = Saturday.
    var weekdays: Set<Int> = Set(1...7)
    var enabled = true

    var timeLabel: String {
        func fmt(_ m: Int) -> String {
            var c = DateComponents(); c.hour = m / 60; c.minute = m % 60
            let d = Calendar.current.date(from: c) ?? Date()
            return d.formatted(date: .omitted, time: .shortened)
        }
        return "\(fmt(startMinutes)) – \(fmt(endMinutes))"
    }
}
