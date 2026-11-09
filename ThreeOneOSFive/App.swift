import SwiftUI
import UIKit
import Foundation

@main
struct ThreeOneOSFiveApp: App {
    @StateObject private var license = LicenseSession()
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
            Group {
            if license.allowed {
                ZStack {
                    ContentView()
                        .preferredColorScheme(.dark)
                        .tint(.white)
                        .environmentObject(license)
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
            } else {
                AccessKeyView(license: license)
            }
            }
            .onChange(of: scenePhase) { phase in
                if phase == .background { license.suspend() }
                if phase == .active { Task { await license.resume() } }
            }
        }
    }
}

private final class LicenseTransport: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
final class LicenseSession: ObservableObject {
    @Published private(set) var allowed = false
    @Published private(set) var busy = false
    @Published private(set) var message = ""
    private var activeKey = ""
    private var generation = UUID()
    private var timer: Task<Void, Never>?
    private let client = URLSession(configuration: .ephemeral, delegate: LicenseTransport(), delegateQueue: nil)

    func suspend() {
        generation = UUID()
        timer?.cancel()
        busy = false
        allowed = false
    }

    func resume() async {
        if !activeKey.isEmpty && !busy && !allowed { _ = await verify(activeKey) }
    }

    func checkForApply() async -> Bool {
        guard allowed, !activeKey.isEmpty else { return false }
        return await verify(activeKey)
    }

    func verify(_ supplied: String) async -> Bool {
        let attempt = UUID()
        generation = attempt
        timer?.cancel()
        busy = true
        message = ""
        let key = supplied.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { if generation == attempt { busy = false } }
        do {
            guard let configured = Bundle.main.object(forInfoDictionaryKey: "LicenseServerURL") as? String,
                  let base = URL(string: configured), base.scheme == "https", base.host != nil,
                  let device = UIDevice.current.identifierForVendor else {
                throw LicenseFailure("Сервер ключей не настроен.")
            }
            var request = URLRequest(url: base.appendingPathComponent("api/check"))
            request.httpMethod = "POST"
            request.timeoutInterval = 10
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(["key": key, "device": device.uuidString])
            let (data, response) = try await client.data(for: request)
            guard generation == attempt else { return false }
            struct Reply: Decodable { let valid: Bool?; let remaining: Int?; let error: String? }
            let reply = try JSONDecoder().decode(Reply.self, from: data)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  reply.valid == true, let seconds = reply.remaining, seconds > 0 else {
                let reasons = ["expired": "Срок ключа истёк.", "full": "Все места на ключе заняты.",
                               "blocked": "Это устройство отключено.", "invalid": "Ключ неверный или отозван."]
                throw LicenseFailure(reasons[reply.error ?? ""] ?? "Сервер не подтвердил доступ.")
            }
            activeKey = key
            allowed = true
            timer = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(min(seconds, 30)) * 1_000_000_000) }
                catch { return }
                guard let self, self.generation == attempt else { return }
                if seconds <= 30 { self.allowed = false }
                // A separate task lets verify cancel the previous timer without cancelling the request.
                Task { _ = await self.verify(key) }
            }
            return true
        } catch {
            guard generation == attempt else { return false }
            activeKey = ""
            allowed = false
            message = (error as? LicenseFailure)?.text ?? "Не удалось проверить ключ. Проверь подключение."
            return false
        }
    }

    private struct LicenseFailure: Error {
        let text: String
        init(_ text: String) { self.text = text }
    }
}

private struct AccessKeyView: View {
    @ObservedObject var license: LicenseSession
    @State private var key = ""


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
                    if !license.message.isEmpty { Text(license.message).foregroundStyle(.red) }
                    Button(action: validate) {
                        Text(license.busy ? "ПРОВЕРЯЕМ…" : "АКТИВИРОВАТЬ").font(.headline.weight(.heavy)).tracking(1.5)
                            .frame(maxWidth: .infinity).padding(.vertical, 17)
                            .foregroundStyle(.black).background(.white, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
                .disabled(license.busy)
                .padding(28).frame(maxWidth: 480)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark).tint(.white)
    }

    private func validate() {
        guard !license.busy else { return }
        Task { _ = await license.verify(key) }
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
