import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Brick", systemImage: "lock.iphone") }
            ModesView()
                .tabItem { Label("Modes", systemImage: "square.stack.3d.up") }
            SchedulesView()
                .tabItem { Label("Schedules", systemImage: "calendar.badge.clock") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(.orange)
        .overlay(alignment: .top) { BannerView() }
        .fullScreenCover(isPresented: .constant(!model.authorized)) {
            OnboardingView()
                .environmentObject(model)
        }
        .onChange(of: model.scanRequested) { _, requested in
            if requested { Task { await model.scanBrick() } }
        }
    }
}

struct BannerView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let banner = model.banner {
            Text(banner.text)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(banner.isError ? Color.red.gradient : Color.green.gradient,
                            in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onTapGesture { model.banner = nil }
                .task(id: banner.id) {
                    try? await Task.sleep(for: .seconds(4))
                    withAnimation { if model.banner?.id == banner.id { model.banner = nil } }
                }
        }
    }
}

struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "lock.iphone")
                .font(.system(size: 72, weight: .semibold))
                .foregroundStyle(.orange)
            Text("Brick Hub").font(.largeTitle.bold())
            Text("Block distracting apps with a tap of an NFC tag, a timer, a schedule - or any Home Assistant trigger.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                Label("Uses Apple's Screen Time to block apps", systemImage: "hourglass")
                Label("Nothing leaves your phone except to your own Home Assistant", systemImage: "house")
                Label("No AI, no accounts, no tracking", systemImage: "hand.raised")
            }
            .font(.callout)
            Spacer()
            Button {
                Task { await model.requestScreenTime() }
            } label: {
                Text("Allow Screen Time access").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(24)
        .tint(.orange)
        .interactiveDismissDisabled()
    }
}

/// Big rounded action button used across the app.
struct ActionButton: View {
    var title: String
    var systemImage: String
    var prominent = true
    var action: () async -> Void
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let button = Button {
            Task { await action() }
        } label: {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .controlSize(.large)
        .disabled(model.busy)

        if prominent {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }
}

func formatDuration(_ seconds: Int) -> String {
    let h = seconds / 3600, m = (seconds % 3600) / 60
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m"
}
