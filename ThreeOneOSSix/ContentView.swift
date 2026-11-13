import SwiftUI
import UIKit

private enum VintageTab: CaseIterable, Identifiable {
    case home
    case patches
    case account

    var id: Self { self }

    func title(in language: AppLanguage) -> String {
        switch self {
        case .home: return language.text("tab.home")
        case .patches: return language.text("tab.patches")
        case .account: return "Аккаунт"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house.fill"
        case .patches: return "shippingbox.fill"
        case .account: return "person.crop.circle.fill"
        }
    }
}

struct ContentView: View {
    @Environment(\.appLanguage) private var language
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var draftCoordinator: PatchDraftCoordinator
    @EnvironmentObject private var store: PatchProjectStore
    @State private var selection: VintageTab = .patches

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                regularLayout
            } else {
                compactLayout
            }
        }
        .tint(AppTheme.accent)
        .imageScale(.small)
        .onChange(of: draftCoordinator.request?.id) { requestID in
            if requestID != nil { selection = .patches }
        }
        .onChange(of: draftCoordinator.importRequest?.id) { requestID in
            if requestID != nil { selection = .patches }
        }
        .patchStorePresentation(store)
    }

    private var compactLayout: some View {
        TabView(selection: $selection) {
            ForEach(VintageTab.allCases) { tab in
                tabContent(tab)
                    .tabItem {
                        CompactTabLabel(title: tab.title(in: language), systemImage: tab.systemImage)
                    }
                    .tag(tab)
            }
        }
    }

    private var regularLayout: some View {
        NavigationSplitView {
            List {
                ForEach(VintageTab.allCases) { tab in
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { selection = tab }
                    } label: {
                        Label(tab.title(in: language), systemImage: tab.systemImage)
                            .fontWeight(tab == selection ? .semibold : .regular)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(tab == selection ? AppTheme.accent.opacity(0.14) : Color.clear)
                    .accessibilityAddTraits(tab == selection ? .isSelected : [])
                }
            }
            .navigationTitle("3105")
            .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 300)
        } detail: {
            tabContent(selection)
                .id(selection)
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder
    private func tabContent(_ tab: VintageTab) -> some View {
        switch tab {
        case .home:
            DashboardView()
        case .patches:
            NavigationStack { PrivateContentView() }
        case .account:
            LicenseAccountView()
        }
    }
}

private struct CompactTabLabel: View {
    let title: String
    let systemImage: String

    @ViewBuilder
    var body: some View {
        if let image = UIImage(
            systemName: systemImage,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        )?.withRenderingMode(.alwaysTemplate) {
            Image(uiImage: image)
        } else {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
        }
        Text(title)
    }
}

private struct DashboardView: View {
    @Environment(\.appLanguage) private var language
    @EnvironmentObject private var appState: AppState
    @State private var showSettings = false
    @State private var showLogs = false

    var body: some View {
        NavigationStack {
            List {
                deviceSection
            }
            .navigationBarTitleDisplayMode(.inline)
            .tint(AppTheme.accent)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showLogs = true } label: {
                        Image(systemName: "apple.terminal")
                    }
                    .accessibilityLabel(language.text("accessibility.open_logs"))
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel(language.text("accessibility.open_settings"))
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showLogs) { LogView() }
        }
    }

    private var deviceSection: some View {
        Section {
            LabeledContent(language.text("dashboard.hardware_model")) {
                Text(AppInfo.displayMachineName)
                    .font(.body.monospaced())
            }
            LabeledContent(language.text("settings.ios_version")) {
                Text("\(AppInfo.osVersion) (\(AppInfo.osBuild))")
                    .font(.body.monospaced())
            }
            HStack {
                Text(language.text("settings.compatibility"))
                Spacer()
                Text(language.text(appState.isSupported ? "settings.supported" : "settings.unsupported"))
                .foregroundStyle(appState.isSupported ? Color.green : Color.red)
            }

            if appState.kernelExploitApplicable && AppInfo.versionTuple.major < 26 {
                HStack {
                    Text(language.text("dashboard.kernel_status"))
                    Spacer()
                    if appState.kernelExploitRunning {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(language.text("dashboard.kernel_running"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(language.text(appState.exploitStatus.isSuccess ? "dashboard.kernel_active" : "dashboard.kernel_inactive"))
                        .foregroundStyle(appState.exploitStatus.isSuccess ? Color.green : Color.secondary)
                    }
                }
            }
        } header: {
            Text(language.text("common.device"))
        } footer: {
            Text(language.text("settings.supported_range_summary"))
        }
    }
}
