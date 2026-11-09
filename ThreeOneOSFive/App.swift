import SwiftUI
import UIKit
import CryptoKit

@main
struct ThreeOneOSFiveApp: App {
    @State private var unlocked = false
    @StateObject private var appState = AppState()
    @StateObject private var patchDraftCoordinator = PatchDraftCoordinator()
    @StateObject private var fileOperationCoordinator = FileOperationCoordinator()
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.english.rawValue
    @State private var showOnboarding = OnboardingStore.shouldShow()
    @State private var showAttribution = false
    @State private var updateOffer: AppUpdateChecker.Offer?
    @Environment(\.scenePhase) private var scenePhase

    init() {
        setupLogCapture()
        log("app: 3105 launching — iOS \(AppInfo.osVersion) (\(AppInfo.osBuild)) \(AppInfo.machineName)")
    }

    private var language: AppLanguage {
        AppLanguage(rawValue: languageCode) ?? .english
    }

    private func checkForUpdate() {
        Task {
            guard let offer = await AppUpdateChecker.check() else { return }
            await MainActor.run { updateOffer = offer }
        }
    }

    var body: some Scene {
        WindowGroup {
            if unlocked {
                ZStack {
                    ContentView()
                        .preferredColorScheme(.dark)
                        .tint(.white)
                        .environmentObject(appState)
                        .environmentObject(patchDraftCoordinator)
                        .environmentObject(fileOperationCoordinator)
                        .environment(\.appLanguage, language)
                        .environment(\.locale, language.locale)
                        .opacity(showOnboarding ? 0 : 1)
                        .allowsHitTesting(!showOnboarding)

                    if showOnboarding {
                        OnboardingView {
                            OnboardingStore.markCompleted()
                            withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                                showOnboarding = false
                            }
                            appState.detectSupport()
                            checkForUpdate()
                        }
                        .environment(\.appLanguage, language)
                        .environment(\.locale, language.locale)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                        .zIndex(1)
                    }
                }
                .displayIdentityAttribution(isPresented: $showAttribution, enabled: !showOnboarding)
                .sheet(isPresented: $showAttribution) {
                    DisplayAttributionSheet()
                }
                .alert(item: $updateOffer) { offer in
                    Alert(
                        title: Text(language.text("update.title")),
                        message: Text(language.text("update.message", offer.version)),
                        primaryButton: .default(Text(language.text("update.agree"))) {
                            UIApplication.shared.open(offer.url)
                        },
                        secondaryButton: .cancel(Text(language.text("update.dismiss"))) {
                            AppUpdateChecker.dismiss(version: offer.version)
                        }
                    )
                }
                .onAppear {
                    if !showOnboarding {
                        appState.detectSupport()
                        checkForUpdate()
                    }
                }
                .onChange(of: scenePhase) { phase in
                    guard phase == .active, !showOnboarding else { return }
                    appState.detectSupport()
                }
                .onOpenURL { url in
                    patchDraftCoordinator.presentImport(url)
                }
            } else {
                AccessKeyView { unlocked = true }
            }
        }
    }
}

private struct AccessKeyView: View {
    let onUnlock: () -> Void
    @State private var key = ""
    @State private var invalid = false

    @State private var revealKey = false

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 26) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 42, weight: .black))
                        .frame(width: 82, height: 82)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 24))
                        .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.2)))
                        .accessibilityHidden(true)
                    VStack(spacing: 8) {
                        Text("VINTAGE LITE").font(.largeTitle.weight(.black)).tracking(2)
                        Text("КЛЮЧ ДОСТУПА").font(.caption.weight(.bold)).tracking(3)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Group {
                            if revealKey { TextField("Введи ключ", text: $key) }
                            else { SecureField("Введи ключ", text: $key) }
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(validate)
                        Button { revealKey.toggle() } label: {
                            Image(systemName: revealKey ? "eye.slash" : "eye").frame(width: 44, height: 44)
                        }
                        .accessibilityLabel(revealKey ? "Скрыть ключ" : "Показать ключ")
                    }
                    .padding(.leading, 16).padding(.trailing, 4).padding(.vertical, 4)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.18)))
                    if invalid { Text("Неверный ключ").foregroundStyle(.red) }
                    Button(action: validate) {
                        Text("АКТИВИРОВАТЬ").font(.headline.weight(.heavy)).tracking(1.5)
                            .frame(maxWidth: .infinity).padding(.vertical, 17)
                            .foregroundStyle(.black).background(.white, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
                .padding(28).frame(maxWidth: 480)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark).tint(.white)
    }

    private func validate() {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let digest = SHA256.hash(data: Data(normalized.utf8))
        if digest.map({ String(format: "%02x", $0) }).joined() == "7d115c541bfbba6fde88baad9a82a83f28fa962e455f82e79289c84552c96592" {
            onUnlock()
        } else {
            invalid = true
        }
    }
}

class AppState: ObservableObject {
    @Published var exploitStatus: ExploitStatus = .notStarted
    @Published var unsupportedMessage: String?
    @Published var kernelExploitRunning = false

    private var autoRunAttempted = false

    var kernelExploitApplicable: Bool {
        KernelExploit.isApplicable(
            major: AppInfo.versionTuple.major,
            minor: AppInfo.versionTuple.minor,
            patch: AppInfo.versionTuple.patch,
            build: AppInfo.osBuild
        )
    }

    var isSupported: Bool { unsupportedMessage == nil }

    func detectSupport() {
        let v = AppInfo.versionTuple
        let supported = ExploitSupportPolicy.isSupported(
            major: v.major,
            minor: v.minor,
            patch: v.patch,
            build: AppInfo.osBuild
        )
#if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--simulate-access") {
            exploitStatus = .success(method: "Simulator preview")
        }
#endif

        unsupportedMessage = supported ? nil : "iOS \(AppInfo.osVersion) (\(AppInfo.osBuild))"
        if let unsupportedMessage {
            exploitStatus = .unsupported(unsupportedMessage)
            return
        }

        let applicable = KernelExploit.isApplicable(
            major: v.major,
            minor: v.minor,
            patch: v.patch,
            build: AppInfo.osBuild
        )
        guard applicable else { return }

        refreshKernelExploitStatus()
        maybeAutoRunKernelExploit()
    }

    private func maybeAutoRunKernelExploit() {
        guard !kernelExploitRunning,
              !exploitStatus.isSuccess,
              !exploitStatus.isFailed,
              !autoRunAttempted else { return }
        autoRunAttempted = true
        log("app: starting kernel exploit automatically")
        runKernelExploitIfNeeded()
    }

    private func refreshKernelExploitStatus() {
        guard !kernelExploitRunning else { return }

        // iOS < 26: kernel R/W success persists (no sandbox probe)
        // iOS >= 26: verify full sandbox escape is still active
        if KernelExploit.requiresSandboxEscape {
            if KernelExploit.hasSandboxAccess() {
                if !exploitStatus.isSuccess {
                    exploitStatus = .success(method: "kexploit")
                    log("app: existing sandbox access is still active; skipping kernel exploit")
                }
            } else if exploitStatus.isSuccess {
                exploitStatus = .notStarted
                log("app: sandbox access is no longer active")
            }
        }
    }

    func runKernelExploitIfNeeded() {
        refreshKernelExploitStatus()
        guard !kernelExploitRunning,
              !exploitStatus.isSuccess,
              !exploitStatus.isFailed else { return }
        kernelExploitRunning = true
        exploitStatus = .notStarted
        log("app: running kernel exploit on background...")
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = KernelExploit.run()
            DispatchQueue.main.async {
                self.kernelExploitRunning = false
                if ok {
                    self.exploitStatus = .success(method: "kexploit")
                    if KernelExploit.requiresSandboxEscape {
                        log("app: kernel exploit success — sandbox access verified")
                    } else {
                        log("app: kernel exploit success — kernel access active")
                    }
                } else {
                    self.exploitStatus = .failed(method: "kexploit", code: -1)
                    log("app: kernel exploit failed — relaunch the app before retrying")
                }
            }
        }
    }
}
