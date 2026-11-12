import SwiftUI

struct CleanerView: View {
    @Environment(\.appLanguage) private var language
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var records: [CleanerAppRecord] = []
    @State private var selectedBundleIDs = Set<String>()
    @State private var searchText = ""
    @EnvironmentObject private var scanCoordinator: ScanCoordinator
    @State private var sortOrder: CleanerSortOrder = .largestFirst
    @State private var isScanning = false
    @State private var isCleaning = false
    @State private var scannedAppCount = 0
    @State private var hasLoaded = false
    @State private var scanID = UUID()
    @State private var activeAlert: CleanerAlert?
    @State private var crashSummary: CrashLogSummary?
    @State private var isCrashBusy = false
    @State private var cleanerHistory: [CleanerHistoryEntry] = []
    @State private var cleaningProgressText = ""
    let confirmationGate = CleanerSafetyPolicy.ConfirmationGate()
    let onOpenSettings: () -> Void

    init(onOpenSettings: @escaping () -> Void = {}) {
        self.onOpenSettings = onOpenSettings
    }

    private var filteredRecords: [CleanerAppRecord] {
        let matchingRecords: [CleanerAppRecord]
        if searchText.isEmpty {
            matchingRecords = records
        } else {
            let query = searchText.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: language.locale
            )
            matchingRecords = records.filter {
                $0.app.displayName.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: language.locale
                ).contains(query) || $0.app.bundleID.lowercased().contains(query.lowercased())
            }
        }

        return CleanerCatalog.sorted(
            matchingRecords,
            order: sortOrder,
            size: { $0.usage.totalBytes },
            displayName: { $0.app.displayName },
            stableID: { $0.id }
        )
    }

    private var visibleBundleIDs: [String] {
        filteredRecords.filter(\.isIdentified).map(\.id)
    }

    private var areAllVisibleRecordsSelected: Bool {
        !visibleBundleIDs.isEmpty && visibleBundleIDs.allSatisfy(selectedBundleIDs.contains)
    }

    private var totalAvailableBytes: Int64 {
        records.reduce(0) { $0 + $1.usage.totalBytes }
    }

    private var selectedBytes: Int64 {
        records.reduce(0) { result, record in
            result + (selectedBundleIDs.contains(record.id) ? record.usage.totalBytes : 0)
        }
    }

    private var isBusy: Bool {
        isScanning || isCleaning
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                AppSearchField(
                    text: $searchText,
                    prompt: language.text("cleaner.search"),
                    clearLabel: language.text("common.clear")
                )
                Divider()
                cleanerList
                    .listStyle(.insetGrouped)
            }
            .navigationTitle(language.text("cleaner.title"))
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar { toolbarContent }
            .alert(item: $activeAlert, content: alert(for:))
            .onAppear {
                guard !hasLoaded else { return }
                hasLoaded = true
                reload()
                loadCrashLogs()
                // History is a small plist; load once per tab entry, not on
                // every struct init (search typing re-inits the view).
                cleanerHistory = CleanerHistory.loadEntries()
            }
        }
    }

    @ViewBuilder
    private var cleanerList: some View {
        if records.isEmpty {
            List {
                crashLogSection
                if isScanning {
                    loadingSection
                } else {
                    emptySection
                }
            }
        } else {
            List {
                summarySection
                crashLogSection
                applicationsSection
                if isScanning {
                    loadingSection
                }
            }
        }
    }

    private var crashLogSection: some View {
        Section {
            if let crashSummary {
                LabeledContent(language.text("cleaner.crash.title")) {
                    Text(language.text(
                        "cleaner.crash.summary",
                        Int64(crashSummary.fileCount),
                        sizeText(crashSummary.bytes)
                    ))
                    .monospacedDigit()
                }
                Button(role: .destructive) {
                    activeAlert = .crashConfirmation
                } label: {
                    Label(language.text("cleaner.crash.clean"), systemImage: "trash")
                }
                .disabled(crashSummary.fileCount == 0 || isCrashBusy)
            } else {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text(language.text("cleaner.crash.loading"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Label(language.text("cleaner.crash.section"), systemImage: "exclamationmark.triangle")
        } footer: {
            Text(language.text("cleaner.crash.footer"))
        }
    }

    private var loadingSection: some View {
        Section {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(language.text(
                    "cleaner.loading_count",
                    Int64(scannedAppCount),
                    Int64(records.count)
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.vertical, 4)
        }
    }

    private var summarySection: some View {
        Section {
            LabeledContent(language.text("cleaner.available")) {
                Text(sizeText(totalAvailableBytes))
                    .monospacedDigit()
            }
            LabeledContent(language.text("cleaner.selected")) {
                Text(language.text("cleaner.selected_summary", Int64(selectedBundleIDs.count), sizeText(selectedBytes)))
                    .monospacedDigit()
            }
            if totalFreedBytes > 0 {
                LabeledContent(language.text("cleaner.history_total")) {
                    Text(sizeText(totalFreedBytes))
                        .monospacedDigit()
                        .foregroundStyle(AppTheme.accent)
                }
            }
            cleanAction
        } header: {
            Label(language.text("cleaner.limited_mode"), systemImage: "checkmark.shield")
        } footer: {
            Text(language.text("cleaner.scope_footer"))
        }
    }

    private var totalFreedBytes: Int64 {
        CleanerHistory.totalFreedBytes(in: cleanerHistory)
    }

    private var applicationsSection: some View {
        Section {
            if filteredRecords.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: AppTheme.emptyIconSize, weight: .light))
                        .foregroundStyle(.secondary)
                    Text(language.text("browser.search_empty"))
                        .font(.headline)
                    Text(language.text("cleaner.search_empty_message"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                ForEach(filteredRecords) { record in
                    Button {
                        toggleSelection(record.id)
                    } label: {
                        applicationRow(record)
                    }
                    .buttonStyle(.plain)
                    .disabled(isCleaning)
                }
            }
        } header: {
            HStack(spacing: 8) {
                Text(language.text("cleaner.apps_with_cache", Int64(filteredRecords.count)))
                Spacer()
                if isScanning {
                    ProgressView()
                        .controlSize(.mini)
                    Text(language.text("cleaner.scanned_count", Int64(scannedAppCount)))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .textCase(nil)
        } footer: {
            if !records.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(language.text("cleaner.apps_footer"))
                    if records.contains(where: { !$0.isIdentified }) {
                        Text(language.text("cleaner.unidentified_footer"))
                    }
                }
            }
        }
    }

    private func applicationRow(_ record: CleanerAppRecord) -> some View {
        HStack(spacing: 10) {
            BrowserAppIcon(app: record.app)

            VStack(alignment: .leading, spacing: 2) {
                Text(record.app.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                Text(record.app.bundleID)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Text(sizeText(record.usage.totalBytes))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Image(systemName: record.isIdentified
                  ? (selectedBundleIDs.contains(record.id) ? "checkmark.circle.fill" : "circle")
                  : "lock.circle")
                .font(.system(size: AppTheme.selectionIconSize, weight: .medium))
                .foregroundStyle(
                    record.isIdentified && selectedBundleIDs.contains(record.id)
                        ? AppTheme.accent
                        : Color.secondary
                )
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityValue(
            selectedBundleIDs.contains(record.id)
                ? language.text("cleaner.accessibility_selected")
                : language.text("cleaner.accessibility_not_selected")
        )
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if !records.isEmpty {
            ToolbarItem(placement: .navigationBarLeading) {
                selectionMenu
            }
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                sortMenu
                refreshButton
                settingsButton
            }
        } else {
            ToolbarItem(placement: .navigationBarLeading) {
                refreshButton
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                settingsButton
            }
        }
    }

    private var settingsButton: some View {
        Button { onOpenSettings() } label: {
            Image(systemName: "gearshape")
        }
        .accessibilityLabel(language.text("settings.title"))
    }

    private var selectionMenu: some View {
        Menu {
            Button {
                selectedBundleIDs = CleanerCatalog.selectingAllVisible(
                    visibleBundleIDs,
                    preserving: selectedBundleIDs
                )
            } label: {
                Label(
                    searchText.isEmpty
                        ? language.text("patch.select_all")
                        : language.text("cleaner.select_all_results"),
                    systemImage: "checkmark.circle"
                )
            }
            .disabled(areAllVisibleRecordsSelected)

            Button {
                selectedBundleIDs.removeAll()
            } label: {
                Label(language.text("patch.deselect_all"), systemImage: "circle")
            }
            .disabled(selectedBundleIDs.isEmpty)
        } label: {
            Image(systemName: "checklist")
        }
        .disabled(isBusy)
        .accessibilityLabel(language.text("cleaner.selection_actions"))
    }

    private var sortMenu: some View {
        Menu {
            Picker(language.text("cleaner.sort"), selection: $sortOrder) {
                Label(
                    language.text("cleaner.sort_largest_first"),
                    systemImage: "arrow.down"
                )
                .tag(CleanerSortOrder.largestFirst)

                Label(
                    language.text("cleaner.sort_smallest_first"),
                    systemImage: "arrow.up"
                )
                .tag(CleanerSortOrder.smallestFirst)
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .disabled(isBusy)
        .accessibilityLabel(language.text("cleaner.sort"))
    }

    private var refreshButton: some View {
        Button { reload(refreshLaunchServices: true) } label: {
            if isScanning {
                ProgressView()
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .disabled(isBusy)
        .accessibilityLabel(language.text("cleaner.scan_again"))
    }

    private var cleanAction: some View {
        Button {
            activeAlert = .confirmation
        } label: {
            HStack(spacing: 8) {
                if isCleaning {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: "trash")
                }
                Text(
                    isCleaning
                        ? (cleaningProgressText.isEmpty
                            ? language.text("cleaner.cleaning")
                            : cleaningProgressText)
                        : language.text("cleaner.clean_button", sizeText(selectedBytes))
                )
                .fontWeight(.semibold)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .disabled(selectedBundleIDs.isEmpty || isBusy)
        .padding(.vertical, 4)
    }

    private var emptySection: some View {
        Section {
            VStack(spacing: 12) {
                if isScanning {
                    ProgressView()
                    Text(language.text("cleaner.scanning"))
                        .font(.headline)
                    Text(language.text("cleaner.scanned_count", Int64(scannedAppCount)))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: AppTheme.emptyIconSize, weight: .light))
                        .foregroundStyle(.secondary)
                    Text(language.text("cleaner.empty_title"))
                        .font(.headline)
                    Text(language.text("cleaner.empty_message"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button(language.text("cleaner.scan_again")) { reload(refreshLaunchServices: true) }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
        }
    }

    private func alert(for alert: CleanerAlert) -> Alert {
        switch alert {
        case .confirmation:
            return Alert(
                title: Text(language.text("cleaner.confirm_title")),
                message: Text(
                    language.text(
                        "cleaner.confirm_message",
                        Int64(selectedBundleIDs.count),
                        sizeText(selectedBytes)
                    )
                ),
                primaryButton: .destructive(Text(language.text("cleaner.confirm_action"))) {
                    // Three-stage gate (WQManager parity): the alert tap only
                    // acknowledges the scope; the actual run must still pass
                    // authorize() bound to the same operation id.
                    let operationID = UUID().uuidString
                    guard confirmationGate.begin(operationID: operationID),
                          confirmationGate.acknowledgeScope(operationID: operationID),
                          confirmationGate.authorize(operationID: operationID) else {
                        confirmationGate.cancel()
                        return
                    }
                    defer { confirmationGate.finish(operationID: operationID) }
                    cleanSelectedApps()
                },
                secondaryButton: .cancel(Text(language.text("common.cancel"))) {
                    confirmationGate.cancel()
                }
            )
        case .result(let message):
            return Alert(
                title: Text(language.text("cleaner.result_title")),
                message: Text(message),
                dismissButton: .default(Text(language.text("common.done")))
            )
        case .crashConfirmation:
            return Alert(
                title: Text(language.text("cleaner.crash.confirm_title")),
                message: Text(language.text("cleaner.crash.confirm_message")),
                primaryButton: .destructive(Text(language.text("cleaner.crash.clean"))) {
                    cleanCrashLogs()
                },
                secondaryButton: .cancel(Text(language.text("common.cancel")))
            )
        case .crashResult(let message):
            return Alert(
                title: Text(language.text("cleaner.crash.result_title")),
                message: Text(message),
                dismissButton: .default(Text(language.text("common.done")))
            )
        }
    }

    private func loadCrashLogs() {
        DispatchQueue.global(qos: .utility).async {
            let summary = CrashLogCleaner.scan()
            DispatchQueue.main.async {
                crashSummary = summary
            }
        }
    }

    private func cleanCrashLogs() {
        isCrashBusy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = CrashLogCleaner.clean()
            let summary = CrashLogCleaner.scan()
            DispatchQueue.main.async {
                isCrashBusy = false
                crashSummary = summary
                activeAlert = .crashResult(message: language.text(
                    "cleaner.crash.result",
                    Int64(result.removed),
                    Int64(result.failed),
                    sizeText(result.freedBytes)
                ))
            }
        }
    }

    private func toggleSelection(_ bundleID: String) {
        guard ContainerPresentationPolicy.isIdentified(bundleID: bundleID) else {
            return
        }
        if selectedBundleIDs.contains(bundleID) {
            selectedBundleIDs.remove(bundleID)
        } else {
            selectedBundleIDs.insert(bundleID)
        }
    }

    private func reload(refreshLaunchServices: Bool = false) {
        guard !isBusy else { return }
        if refreshLaunchServices {
            ContainerStore.refreshLaunchServicesSnapshot()
        }
#if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--simulate-cleaner-empty") {
            records = []
            selectedBundleIDs = []
            scannedAppCount = 388
            isScanning = false
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--simulate-cleaner-data") {
            let samples = [
                CleanerAppRecord(
                    app: InstalledApp(
                        bundleID: "com.lemon.lvoverseas",
                        name: "CapCut",
                        containerPath: "/tmp/CapCut",
                        version: "",
                        icon: nil
                    ),
                    usage: LimitedCleanerUsage(
                        cacheBytes: 184_549_376,
                        temporaryBytes: 12_582_912,
                        removableItemCount: 284
                    )
                ),
                CleanerAppRecord(
                    app: InstalledApp(
                        bundleID: "com.apple.Maps",
                        name: "Maps",
                        containerPath: "/tmp/Maps",
                        version: "",
                        icon: nil
                    ),
                    usage: LimitedCleanerUsage(
                        cacheBytes: 61_865_984,
                        temporaryBytes: 3_145_728,
                        removableItemCount: 92
                    )
                ),
                CleanerAppRecord(
                    app: InstalledApp(
                        bundleID: "com.apple.mobilesafari",
                        name: "Safari",
                        containerPath: "/tmp/Safari",
                        version: "",
                        icon: nil
                    ),
                    usage: LimitedCleanerUsage(
                        cacheBytes: 27_262_976,
                        temporaryBytes: 1_048_576,
                        removableItemCount: 48
                    )
                )
            ]
            records = samples
            selectedBundleIDs = Set(samples.prefix(2).map(\.id))
            scannedAppCount = 388
            isScanning = false
            if ProcessInfo.processInfo.arguments.contains("--simulate-cleaner-warning") {
                activeAlert = .confirmation
            }
            return
        }
#endif
        let requestID = UUID()
        scanID = requestID
        isScanning = true
        scannedAppCount = 0
        selectedBundleIDs.removeAll()
        records.removeAll()

        DispatchQueue.global(qos: .userInitiated).async {
            var scannedBundleIDs = Set<String>()
            var examinedBundleIDs = Set<String>()
            var discoveredRecords: [CleanerAppRecord] = []
            var processedCount = 0
            var lastPublishAt = Date.distantPast

            func publish(force: Bool = false) {
                // Publishing after every app floods the main queue when a
                // device has hundreds of apps; switching tabs then freezes.
                // Throttle to a few updates per second and flush at the end of
                // each batch.
                let now = Date()
                guard force || now.timeIntervalSince(lastPublishAt) >= 0.25 else {
                    return
                }
                lastPublishAt = now
                let snapshot = discoveredRecords.sorted {
                    $0.app.displayName.localizedCaseInsensitiveCompare($1.app.displayName) == .orderedAscending
                }
                let count = processedCount
                DispatchQueue.main.async {
                    guard scanID == requestID else { return }
                    records = snapshot
                    scannedAppCount = count
                }
            }

            func scanNewApps(_ applications: [InstalledApp]) {
                let metadata = Dictionary(
                    applications.map {
                        ($0.bundleID, $0)
                    },
                    uniquingKeysWith: { first, _ in first }
                )
                let catalogApplications = applications.map {
                    CleanerResolvedApplication(
                        bundleID: $0.bundleID,
                        name: $0.name,
                        containerPath: $0.containerPath,
                        version: $0.version
                    )
                }
                _ = CleanerCatalog.scanNewApplications(
                    catalogApplications,
                    scannedBundleIDs: &scannedBundleIDs,
                    // Unidentified containers are scanned too: they are real
                    // app data and the user asked to see everything. They are
                    // shown with a lock and cannot be selected for cleaning.
                    shouldIncludeBundleID: { _ in true },
                    activateContainer: { application in
                        // Filesystem enumeration already knows the exact
                        // container; do not throw it away when MCM/LS fail.
                        if ContainerStore.isApplicationContainerPath(application.containerPath) {
                            return application.containerPath
                        }
                        if let resolved = ContainerStore.resolveAppContainerPath(
                            bundleID: application.bundleID
                        ), ContainerStore.isApplicationContainerPath(resolved) {
                            return resolved
                        }
                        return nil
                    },
                    isValidContainerPath: ContainerStore.isApplicationContainerPath,
                    usageForContainer: { containerPath in
                        do {
                            return try LimitedCleanerService.scan(
                                containerURL: URL(fileURLWithPath: containerPath, isDirectory: true),
                                rootValidator: { ContainerStore.isApplicationContainerPath($0.path) }
                            )
                        } catch {
                            log("cleaner: scan failed \(containerPath) error=\(error)")
                            return nil
                        }
                    },
                    onApplication: { bundleID in
                        guard examinedBundleIDs.insert(bundleID).inserted else { return }
                        processedCount = examinedBundleIDs.count
                        publish()
                    },
                    onRecord: { record in
                        let original = metadata[record.bundleID]
                        let resolvedApp = InstalledApp(
                            bundleID: record.bundleID,
                            name: record.application.name,
                            containerPath: record.containerPath,
                            version: record.application.version,
                            icon: original?.icon
                        )
                        discoveredRecords.append(
                            CleanerAppRecord(app: resolvedApp, usage: record.usage)
                        )
                    }
                )
                publish(force: true)
            }

            let catalogApps = ContainerStore.installedAppsFromCatalog()
            if !catalogApps.isEmpty {
                log("cleaner: catalog fast path \(catalogApps.count) apps")
                scanNewApps(catalogApps)
            }

            let apiApps = ContainerStore.installedAppsFromAPI()
            let dynamicIdentifiers = catalogApps.isEmpty
                ? ContainerStore.dynamicAppIdentifiers()
                : []
            let mcmApps = catalogApps.isEmpty
                ? ContainerStore.installedAppsFromMCM(identifiers: dynamicIdentifiers)
                : []
            scanNewApps(apiApps + mcmApps)

            let launchServicesIdentifiers: [String] = catalogApps.isEmpty
                ? ContainerStore.launchServicesStoreIdentifiers()
                : Array(Set(catalogApps.map(\.bundleID)))

            // MCM/LS can be empty inside signing containers such as
            // LiveContainer; enumerate the app-data root directly and resolve
            // identities through the container index, exactly like App Data.
            let knownAppsByBundleID = Dictionary(
                (apiApps + mcmApps).map { ($0.bundleID, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let resolvedFilesystemApps: [InstalledApp]
            if catalogApps.isEmpty {
                let token = ScanToken()
                DispatchQueue.main.async {
                    scanCoordinator.begin(
                        title: language.text("scan.title.cleaner"),
                        message: language.text("scan.message.cleaner"),
                        token: token
                    )
                }
                resolvedFilesystemApps = ContainerStore.containersFromFilesystem(token: token) { done, total in
                    DispatchQueue.main.async {
                        scanCoordinator.update(done: done, total: total)
                    }
                }.map {
                    ContainerStore.inferredApp(
                        for: $0,
                        knownAppsByBundleID: knownAppsByBundleID,
                        launchServicesIdentifiers: Set(launchServicesIdentifiers)
                    ) ?? $0
                }
                DispatchQueue.main.async {
                    scanCoordinator.finish()
                }
            } else {
                resolvedFilesystemApps = []
            }
            scanNewApps(resolvedFilesystemApps)

            let candidates = catalogApps.isEmpty ? MHAIdentifierCatalog.identifiers(
                dynamic: dynamicIdentifiers,
                installed: apiApps.map(\.bundleID),
                research: ContainerStore.researchAppIdentifiers,
                custom: [],
                launchServices: launchServicesIdentifiers
            ) : []
            log("cleaner: resolving \(candidates.count) MHA-C2 bundle candidates")
            let mhaApps = ContainerStore.installedAppsFromMHACandidates(
                identifiers: candidates
            ) { progressiveApps in
                scanNewApps(progressiveApps)
            }
            scanNewApps(mhaApps)
            log("cleaner: scan finished apps=\(scannedBundleIDs.count) records=\(discoveredRecords.count)")
            publish(force: true)

            DispatchQueue.main.async {
                guard scanID == requestID else { return }
                isScanning = false
                log(
                    "cleaner: scan complete bundles=\(processedCount) " +
                        "reclaimableApps=\(discoveredRecords.count)"
                )
            }
        }
    }

    private func cleanSelectedApps() {
        guard !isBusy else { return }
        let selectedRecords = records.filter { selectedBundleIDs.contains($0.id) }
        guard !selectedRecords.isEmpty else { return }
        isCleaning = true
        cleaningProgressText = ""

        DispatchQueue.global(qos: .userInitiated).async {
            var updatedUsage: [String: LimitedCleanerUsage] = [:]
            var freedBytes: Int64 = 0
            var removedItems = 0
            var failedItems = 0
            var unavailableApps = 0
            let totalSelected = selectedRecords.count
            var processedIndex = 0
            var lastProgressPublish = Date.distantPast

            for record in selectedRecords {
                processedIndex += 1
                // Throttled per-app progress: the clean of many large apps
                // takes minutes; a bare spinner read as "hung".
                let now = Date()
                if now.timeIntervalSince(lastProgressPublish) >= 0.5 {
                    lastProgressPublish = now
                    let progressText = language.text(
                        "cleaner.progress",
                        processedIndex, totalSelected,
                        sizeText(freedBytes), record.app.displayName
                    )
                    DispatchQueue.main.async {
                        cleaningProgressText = progressText
                    }
                }
                // The scan already resolved the exact container. Re-resolving
                // by bundle id fails whenever MCM is unavailable.
                let containerPath: String
                if ContainerStore.isApplicationContainerPath(record.app.containerPath) {
                    containerPath = record.app.containerPath
                } else if let resolved = ContainerStore.resolveAppContainerPath(
                    bundleID: record.app.bundleID
                ) {
                    containerPath = resolved
                } else {
                    unavailableApps += 1
                    log("cleaner: bundle unavailable \(record.app.bundleID)")
                    continue
                }
                log("cleaner: cleaning \(record.app.bundleID) at \(containerPath)")

                do {
                    let result = try LimitedCleanerService.clean(
                        containerURL: URL(fileURLWithPath: containerPath, isDirectory: true),
                        rootValidator: { ContainerStore.isApplicationContainerPath($0.path) }
                    )
                    updatedUsage[record.id] = result.after
                    freedBytes += result.freedBytes
                    removedItems += result.removedItemCount
                    failedItems += result.failedItemCount
                    log(
                        "cleaner: cleaned \(record.app.bundleID) " +
                            "freed=\(result.freedBytes) removed=\(result.removedItemCount) " +
                            "failed=\(result.failedItemCount)"
                    )
                } catch {
                    unavailableApps += 1
                    log("cleaner: failed \(record.app.bundleID) error=\(error)")
                }
            }

            let resultMessage = language.text(
                "cleaner.result_message",
                sizeText(freedBytes),
                Int64(removedItems),
                Int64(failedItems + unavailableApps)
            )
            let cleanedCount = selectedRecords.count - unavailableApps
            let historyEntry = CleanerHistoryEntry(
                cleanedAppCount: max(0, cleanedCount),
                failedItemCount: failedItems + unavailableApps,
                freedBytes: freedBytes
            )
            DispatchQueue.main.async {
                records = records.compactMap { record in
                    guard let usage = updatedUsage[record.id] else { return record }
                    guard usage.totalBytes > 0 else { return nil }
                    return CleanerAppRecord(app: record.app, usage: usage)
                }
                cleaningProgressText = ""
                selectedBundleIDs.removeAll()
                cleanerHistory = CleanerHistory.record(historyEntry)
                ActivityHistory.log(
                    .clean,
                    feature: "cleaner",
                    "apps=\(historyEntry.cleanedAppCount) freed=\(historyEntry.totalFreedBytes)"
                )
                isCleaning = false
                activeAlert = .result(message: resultMessage)
            }
        }
    }

    private func sizeText(_ byteCount: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }
}

private struct CleanerAppRecord: Identifiable {
    let app: InstalledApp
    let usage: LimitedCleanerUsage

    var id: String { app.bundleID }
    var isIdentified: Bool {
        ContainerPresentationPolicy.isIdentified(bundleID: app.bundleID)
    }
}

private enum CleanerAlert: Identifiable {
    case confirmation
    case result(message: String)
    case crashConfirmation
    case crashResult(message: String)

    var id: String {
        switch self {
        case .confirmation: return "confirmation"
        case .crashConfirmation: return "crashConfirmation"
        case .result(let message): return "result-\(message)"
        case .crashResult(let message): return "crashResult-\(message)"
        }
    }
}
