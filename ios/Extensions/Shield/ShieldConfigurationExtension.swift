import ManagedSettings
import ManagedSettingsUI
import UIKit

/// The screen you see when opening a bricked app.
final class ShieldConfigurationExtension: ShieldConfigurationDataSource {
    private func make() -> ShieldConfiguration {
        let store = SharedStore.shared
        let state = store.book.state
        let modeName = store.mode(state.modeId)?.name
        var subtitle = "Scan your brick to unlock."
        if let end = state.endsAt, end > Date() {
            subtitle = "Unlocks at \(end.formatted(date: .omitted, time: .shortened)) - or scan your brick."
        }
        if let modeName { subtitle = "\(modeName). " + subtitle }
        return ShieldConfiguration(
            backgroundBlurStyle: .systemUltraThinMaterialDark,
            backgroundColor: UIColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1),
            icon: UIImage(systemName: "lock.fill")?.withTintColor(.white, renderingMode: .alwaysOriginal),
            title: ShieldConfiguration.Label(text: "Bricked", color: .white),
            subtitle: ShieldConfiguration.Label(text: subtitle, color: .lightGray),
            primaryButtonLabel: ShieldConfiguration.Label(text: "OK", color: .black),
            primaryButtonBackgroundColor: .white
        )
    }

    override func configuration(shielding application: Application) -> ShieldConfiguration { make() }

    override func configuration(shielding application: Application,
                                in category: ActivityCategory) -> ShieldConfiguration { make() }

    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration { make() }

    override func configuration(shielding webDomain: WebDomain,
                                in category: ActivityCategory) -> ShieldConfiguration { make() }
}
