import SwiftUI

/// The landing page: a local feature hub instead of a remote repository feed.
/// Everything that used to occupy its own tab bar slot (market, sources,
/// installed patches) is reachable from here, keeping the bottom bar at five
/// fixed destinations.
struct FeatureHubView: View {
    @Environment(\.appLanguage) private var language
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Page-level single entrance: the whole card list fades/slides in once.
    // Per-row @State animations would replay when List recycles rows.
    @State private var entranceShown = false
    let onSelectTab: (AppSection) -> Void
    let onOpenSettings: () -> Void
    let onOpenLogs: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent(language.text("home.version"), value: appVersion)
                    LabeledContent(
                        language.text("home.backend"),
                        value: SandboxAccess.backend.displayName
                    )
                    if SandboxAccess.needsWorseQuery {
                        LabeledContent(
                            language.text("home.app_group"),
                            value: appGroupText
                        )
                        if SandboxAccess.appGroup == nil {
                            Text(language.text("home.app_group_warning"))
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                } header: {
                    Text(language.text("home.status"))
                }

                Section {
                    NavigationLink {
                        GestaltCardsView()
                    } label: {
                        card(
                            "home.card.gestalt",
                            detail: "home.card.gestalt_detail",
                            icon: "cpu.fill"
                        )
                    }

                    NavigationLink {
                        KeypadThemeView()
                    } label: {
                        card(
                            "home.card.keypad",
                            detail: "home.card.keypad_detail",
                            icon: "circle.grid.3x3.fill"
                        )
                    }

                    NavigationLink {
                        SupervisedModeView()
                    } label: {
                        card(
                            "home.card.supervised",
                            detail: "home.card.supervised_detail",
                            icon: "checkmark.shield"
                        )
                    }

                    NavigationLink {
                        WallpaperLabView(
                            onOpenSettings: onOpenSettings,
                            onOpenLogs: onOpenLogs
                        )
                    } label: {
                        card(
                            "home.card.wallpapers",
                            detail: "home.card.wallpapers_detail",
                            icon: "photo.on.rectangle.angled"
                        )
                    }
                } header: {
                    Text(language.text("home.section.device"))
                }

                Section {
                    NavigationLink {
                        PatchProjectsView(
                            onOpenSettings: onOpenSettings,
                            onOpenLogs: onOpenLogs
                        )
                    } label: {
                        card(
                            "home.card.patches",
                            detail: "home.card.patches_detail",
                            icon: "square.stack.3d.up.fill"
                        )
                    }

                    NavigationLink {
                        RepositoryNewView(
                            onOpenSettings: onOpenSettings,
                            onOpenLogs: onOpenLogs
                        )
                    } label: {
                        card(
                            "home.card.market",
                            detail: "home.card.market_detail",
                            icon: "sparkles"
                        )
                    }

                    NavigationLink {
                        RepositorySourcesView(
                            onOpenSettings: onOpenSettings,
                            onOpenLogs: onOpenLogs
                        )
                    } label: {
                        card(
                            "home.card.sources",
                            detail: "home.card.sources_detail",
                            icon: "shippingbox.fill"
                        )
                    }
                } header: {
                    Text(language.text("home.section.apps"))
                }

                Section {
                    Button {
                        onSelectTab(.files)
                    } label: {
                        card(
                            "home.card.files",
                            detail: "home.card.files_detail",
                            icon: "folder.fill"
                        )
                    }
                    .buttonStyle(.plain)

                    Button {
                        onSelectTab(.search)
                    } label: {
                        card(
                            "home.card.search",
                            detail: "home.card.search_detail",
                            icon: "magnifyingglass"
                        )
                    }
                    .buttonStyle(.plain)

                    Button {
                        onSelectTab(.cleaner)
                    } label: {
                        card(
                            "home.card.cleaner",
                            detail: "home.card.cleaner_detail",
                            icon: "sparkles"
                        )
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        BackupCenterView()
                    } label: {
                        card(
                            "home.card.backups",
                            detail: "home.card.backups_detail",
                            icon: "externaldrive.fill"
                        )
                    }

                    NavigationLink {
                        AppSaveBackupView()
                    } label: {
                        card(
                            "home.card.savebackups",
                            detail: "home.card.savebackups_detail",
                            icon: "arrow.down.doc.fill"
                        )
                    }

                    NavigationLink {
                        FileReplaceView()
                    } label: {
                        card(
                            "home.card.filereplace",
                            detail: "home.card.filereplace_detail",
                            icon: "arrowshape.replace.forward.fill"
                        )
                    }
                } header: {
                    Text(language.text("home.section.data"))
                }

                Section {
                    NavigationLink {
                        LogView()
                    } label: {
                        card(
                            "home.card.logs",
                            detail: "home.card.logs_detail",
                            icon: "apple.terminal.fill"
                        )
                    }

                    NavigationLink {
                        AcknowledgementsView()
                    } label: {
                        card(
                            "home.card.ack",
                            detail: "home.card.ack_detail",
                            icon: "heart.text.square.fill"
                        )
                    }

                    RespringButton()

                    Button(action: onOpenSettings) {
                        card(
                            "home.card.settings",
                            detail: "home.card.settings_detail",
                            icon: "gear"
                        )
                    }
                    .buttonStyle(.plain)
                } header: {
                    Text(language.text("home.section.about"))
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(language.text("tab.features"))
            .navigationBarTitleDisplayMode(.inline)
            .opacity(entranceShown ? 1 : 0)
            .offset(y: entranceShown ? 0 : 10)
            .onAppear {
                guard !entranceShown, !reduceMotion else {
                    entranceShown = true
                    return
                }
                withAnimation(.easeOut(duration: 0.3)) {
                    entranceShown = true
                }
            }
            .toolbar {
                AppUtilityToolbar(
                    language: language,
                    onOpenSettings: onOpenSettings,
                    onOpenLogs: onOpenLogs
                )
            }
        }
    }

    private func card(
        _ titleKey: String,
        detail: String,
        icon: String
    ) -> some View {
        HStack(spacing: 12) {
            AppRowIcon(systemName: icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(language.text(titleKey))
                    .foregroundStyle(.primary)
                Text(language.text(detail))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    private var appGroupText: String {
        SandboxAccess.appGroup ?? language.text("home.app_group_missing")
    }
}