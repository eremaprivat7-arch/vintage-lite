import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appLanguage) private var language
    @EnvironmentObject private var appState: AppState
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.english.rawValue
    // Mirrors SoundEffects.isEnabled so the effect player reads one source of
    // truth (UserDefaults) while the toggle gets @AppStorage semantics.
    @AppStorage("sound.effects.enabled") private var soundEffectsEnabled = true
    // Gates high-risk experimental flows (Siri AI experimental mode) behind
    // an explicit opt-in; the flows stay hidden until this is on.
    @AppStorage(FeatureVisibility.developerModeStorageKey) private var experimentalFeaturesEnabled = false
    @State private var showAccount = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        AppLogo()

                        VStack(alignment: .leading, spacing: 3) {
                            Text("VintageLite").font(.headline)
                            Text("Версия \(VintageRelease.version) · сборка \(VintageRelease.build)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Аккаунт VintageLite") {
                    Button { showAccount = true } label: {
                        Label("Ключ, срок и бонус", systemImage: "person.crop.circle")
                    }
                }

                Section(language.text("settings.language")) {
                    Picker(language.text("settings.language"), selection: $languageCode) {
                        ForEach(AppLanguage.allCases) { option in
                            Text(option.displayName).tag(option.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                Section {
                    NavigationLink {
                        BackupCenterView()
                    } label: {
                        Label(
                            language.text("backup.title"),
                            systemImage: "externaldrive.badge.timemachine"
                        )
                    }

                    NavigationLink {
                        AcknowledgementsView()
                    } label: {
                        Label(
                            language.text("ack.title"),
                            systemImage: "heart.text.square.fill"
                        )
                    }

                    RespringButton()
                } header: {
                    Text(language.text("settings.backup"))
                }

                Section {
                    Toggle(isOn: $soundEffectsEnabled) {
                        Label(
                            language.text("settings.sound_effects"),
                            systemImage: "speaker.wave.2"
                        )
                    }
                } header: {
                    Text(language.text("settings.sound_effects"))
                } footer: {
                    Text(language.text("settings.sound_effects_footer"))
                }

                Section("Обновления VintageLite") {
                    Link("Новая версия · @osinxshop",
                         destination: URL(string: "https://t.me/osinxshop")!)
                }

                Section {
                    Toggle(isOn: $experimentalFeaturesEnabled) {
                        Label(
                            language.text("settings.experimental"),
                            systemImage: "flask"
                        )
                    }
                } header: {
                    Text(language.text("settings.experimental_header"))
                } footer: {
                    Text(language.text("settings.experimental_footer"))
                }

                if WallpaperFeatureSupportPolicy.isSupported(
                    major: AppInfo.versionTuple.major
                ) {
                    Section {
                        NavigationLink {
                            WallpaperResetSettingsView()
                        } label: {
                            Label(
                                language.text("wallpaper.reset"),
                                systemImage: "arrow.counterclockwise"
                            )
                        }
                    } header: {
                        Text(language.text("tab.wallpapers"))
                    } footer: {
                        Text(language.text("wallpaper.reset_settings_footer"))
                    }
                }

                Section(language.text("common.device")) {
                    LabeledContent(language.text("dashboard.hardware_model"), value: AppInfo.displayMachineName)
                    LabeledContent(language.text("settings.ios_version"), value: "\(AppInfo.osVersion) (\(AppInfo.osBuild))")
                    LabeledContent(language.text("settings.access_backend"), value: SandboxAccess.backend.displayName)
                    LabeledContent(language.text("settings.app_group"), value: appGroupStatus)
                }

                Section {
                    HStack {
                        Text(language.text("settings.current_version"))
                        Spacer()
                        Text(language.text(appState.isSupported ? "settings.supported" : "settings.unsupported"))
                        .foregroundStyle(appState.isSupported ? Color.green : Color.red)
                    }
                    LabeledContent("iOS 17", value: ExploitSupportPolicy.verifiedIOS17Range)
                    LabeledContent("iOS 18", value: ExploitSupportPolicy.verifiedIOS18Range)
                    LabeledContent(
                        "iOS 26",
                        value: "\(ExploitSupportPolicy.verifiedIOS26BadQueryRange) · \(ExploitSupportPolicy.verifiedIOS26WorseQueryRange)"
                    )
                    LabeledContent("iOS 27", value: ExploitSupportPolicy.verifiedIOS27Range)
                } header: {
                    Text(language.text("settings.verified_versions"))
                } footer: {
                    Text(language.text("settings.supported_versions_footer"))
                }

                Section("Социальные сети") {
                    Link("Telegram-канал · @osinxshop",
                         destination: URL(string: "https://t.me/osinxshop")!)
                    Link("Поддержка · @osinxff",
                         destination: URL(string: "https://t.me/osinxff")!)
                }
            }
            .sheet(isPresented: $showAccount) { LicenseAccountView() }
            .tint(AppTheme.accent)
            .navigationTitle(language.text("settings.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(language.text("common.done")) { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private var appGroupStatus: String {
        guard SandboxAccess.needsWorseQuery else { return "—" }
        return SandboxAccess.appGroup ?? language.text("settings.app_group_missing")
    }

    }