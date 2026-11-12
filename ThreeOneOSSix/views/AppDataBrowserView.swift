import SwiftUI
import UIKit

struct AppDataBrowserView: View {
    @Environment(\.appLanguage) private var language
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var scanCoordinator: ScanCoordinator
    @State private var apps: [InstalledApp] = []
    @State private var unidentifiedApps: [InstalledApp] = []
    @State private var isLoading = false
    @State private var isResolving = false
    @State private var searchText = ""
    @State private var errorMessage: String?
    @State private var hasLoaded = false
    @State private var workspaceURL: URL?
    @State private var catalogCreatedAt: Date?
    @State private var sortByName = true
    @State private var containerSizes: [String: Int64] = [:]
    @AppStorage("browser.containerSizes") private var containerSizesJSON: String = "{}"
    @Binding private var tabSession: FilesTabSession
    let onOpenSettings: () -> Void
    let onOpenLogs: () -> Void

    init(
        tabSession: Binding<FilesTabSession>,
        onOpenSettings: @escaping () -> Void = {},
        onOpenLogs: @escaping () -> Void = {}
    ) {
        _tabSession = tabSession
        self.onOpenSettings = onOpenSettings
        self.onOpenLogs = onOpenLogs
    }

    private var filteredApps: [InstalledApp] {
        let base: [InstalledApp]
        if searchText.isEmpty {
            base = apps
        } else {
            let q = searchText.lowercased()
            base = apps.filter {
                $0.name.lowercased().contains(q) || $0.bundleID.lowercased().contains(q)
            }
        }
        if sortByName {
            return base.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        }
        let sizes = containerSizes
        return base.sorted { left, right in
            let leftSize = sizes[left.bundleID] ?? -1
            let rightSize = sizes[right.bundleID] ?? -1
            if leftSize != rightSize { return leftSize > rightSize }
            return left.displayName.localizedCaseInsensitiveCompare(right.displayName) == .orderedAscending
        }
    }

    private var decodedContainerSizes: [String: Int64] {
        guard let data = containerSizesJSON.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: Int64].self, from: data)
        else { return [:] }
        return dict
    }

    private var catalogAgeText: String? {
        guard let catalogCreatedAt else { return nil }
        let minutes = max(0, Int(Date().timeIntervalSince(catalogCreatedAt) / 60))
        if minutes < 1 {
            return language.text("browser.index_just_now")
        }
        return language.text("browser.index_age", minutes)
    }

    private var filteredUnidentifiedApps: [InstalledApp] {
        guard !searchText.isEmpty else { return unidentifiedApps }
        let q = searchText.lowercased()
        return unidentifiedApps.filter {
            $0.name.lowercased().contains(q) || $0.bundleID.lowercased().contains(q)
        }
    }

    private var overlayState: AppBrowserOverlayState {
        let total = apps.count + unidentifiedApps.count
        let filtered = filteredApps.count + filteredUnidentifiedApps.count
        if (isLoading || isResolving) && total == 0 { return .loading }
        if total == 0 { return .empty }
        if filtered == 0 { return .noResults }
        return .none
    }

    private var interfaceAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.20)
    }

    var body: some View {
        navigationContent(tabID: tabSession.selectedTabID)
            .id(tabSession.selectedTabID)
    }

    private func navigationContent(tabID: UUID) -> some View {
        NavigationStack(path: navigationPath(for: tabID)) {
            appList
            .navigationTitle(language.text("browser.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    FilesTabToolbarButton(session: $tabSession)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    sortMenu
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { reload(refreshLaunchServices: true) } label: {
                        if isResolving {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(isResolving)
                    .accessibilityLabel(language.text("browser.retry"))
                }
                AppUtilityToolbar(
                    language: language,
                    onOpenSettings: onOpenSettings,
                    onOpenLogs: onOpenLogs
                )
            }
            .onAppear {
                // Decode the persisted size map once per view instance, not
                // per row render (rows used to JSON-decode it every body).
                if containerSizes.isEmpty {
                    containerSizes = decodedContainerSizes
                }
                if workspaceURL == nil {
                    workspaceURL = try? PatchWorkspaceService.documentsRootURL()
                    _ = try? PatchWorkspaceService.patchesRootURL()
                }
                if !hasLoaded {
                    hasLoaded = true
                    reload()
                }
            }
            .navigationDestination(for: FileBrowserDestination.self) { destination in
                if destination.startPath == destination.containerPath {
                    FileBrowserView(
                        containerPath: destination.containerPath,
                        title: destination.title,
                        bundleID: destination.bundleID,
                        filesTabSession: $tabSession
                    )
                } else {
                    FileBrowserView(
                        containerPath: destination.containerPath,
                        startPath: destination.startPath,
                        title: destination.title,
                        bundleID: destination.bundleID,
                        filesTabSession: $tabSession
                    )
                }
            }
        }
    }

    private func navigationPath(for tabID: UUID) -> Binding<[FileBrowserDestination]> {
        Binding(
            get: { tabSession.navigationPath(for: tabID) },
            set: { tabSession.setNavigationPath($0, for: tabID) }
        )
    }

    private var appList: some View {
        VStack(spacing: 0) {
            if horizontalSizeClass == .regular {
                FilesTabStrip(session: $tabSession)
            }
            AppSearchField(
                text: $searchText,
                prompt: language.text("browser.search"),
                clearLabel: language.text("common.clear")
            )
            Divider()
            appRows
        }
    }

    private var appRows: some View {
        List {
            if let workspaceURL {
                Section(language.text("browser.workspace")) {
                    let workspaceDestination = FileBrowserDestination(
                        containerPath: workspaceURL.path,
                        startPath: workspaceURL.path,
                        title: "VintageLite",
                        bundleID: nil
                    )
                    NavigationLink(value: workspaceDestination) {
                        HStack(spacing: 10) {
                            AppRowIcon(systemName: "folder.fill")
                            VStack(alignment: .leading, spacing: 2) {
                                Text("VintageLite")
                                    .font(.subheadline.weight(.semibold))
                                Text(language.text("browser.workspace_subtitle"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .contextMenu {
                        openInNewTabButton(workspaceDestination)
                    }
                }
            }
            Section {
                ForEach(filteredApps) { app in
                    if app.containerPath.isEmpty {
                        appRow(app)
                    } else {
                        let appDestination = FileBrowserDestination(
                            containerPath: app.containerPath,
                            startPath: app.containerPath,
                            title: app.displayName,
                            bundleID: app.bundleID
                        )
                        NavigationLink(value: appDestination) {
                            appRow(app)
                        }
                        .contextMenu {
                            openInNewTabButton(appDestination)
                        }
                    }
                }
            } header: {
                HStack(spacing: 8) {
                    Text(language.text("browser.apps_count", Int64(filteredApps.count)))
                    if let catalogAgeText {
                        Text("·")
                        Text(catalogAgeText)
                    }
                    Spacer()
                    if isResolving {
                        ProgressView()
                            .controlSize(.mini)
                        Text(language.text("browser.mha_scanning"))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(nil)
            }
            if !filteredUnidentifiedApps.isEmpty {
                Section {
                    ForEach(filteredUnidentifiedApps) { app in
                        let destination = FileBrowserDestination(
                            containerPath: app.containerPath,
                            startPath: app.containerPath,
                            title: app.displayName,
                            bundleID: nil,
                            readOnly: true
                        )
                        NavigationLink(value: destination) {
                            unidentifiedAppRow(app)
                        }
                        .contextMenu {
                            openInNewTabButton(destination)
                        }
                    }
                } header: {
                    Text(language.text(
                        "browser.unidentified_count",
                        Int64(filteredUnidentifiedApps.count)
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(nil)
                } footer: {
                    Text(language.text("browser.unidentified_footer"))
                }
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.defaultMinListRowHeight, 48)
        .scrollDismissesKeyboard(.interactively)
        .overlay {
            Group {
                switch overlayState {
                case .loading:
                    ProgressView(language.text("browser.loading"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .empty:
                    emptyView
                case .noResults:
                    searchEmptyView
                case .none:
                    EmptyView()
                }
            }
            .transition(.opacity)
            .animation(interfaceAnimation, value: overlayState)
        }
    }

    private func unidentifiedAppRow(_ app: InstalledApp) -> some View {
        HStack(spacing: 10) {
            BrowserAppIcon(app: app)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                Text(app.bundleID)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Text(language.text("browser.unidentified_badge"))
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12), in: Capsule())
        }
        .padding(.vertical, 2)
    }

    private func appRow(_ app: InstalledApp) -> some View {
        HStack(spacing: 10) {
            BrowserAppIcon(app: app)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                Text(app.bundleID)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if !app.version.isEmpty {
                Text(app.version)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // Container size (incremental cache; "·" until measured).
            Text(containerSizeText(for: app))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 12))
    }

    private func containerSizeText(for app: InstalledApp) -> String {
        guard !app.containerPath.isEmpty else { return "·" }
        guard let bytes = containerSizes[app.bundleID], bytes > 0 else { return "·" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var sortMenu: some View {
        Menu {
            Button {
                sortByName = true
            } label: {
                Label(
                    language.text("browser.sort_by_name"),
                    systemImage: sortByName ? "checkmark" : "textformat.abc"
                )
            }
            Button {
                sortByName = false
                scheduleContainerSizeMeasurement()
            } label: {
                Label(
                    language.text("browser.sort_by_size"),
                    systemImage: sortByName ? "arrow.up.arrow.down" : "checkmark"
                )
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .accessibilityLabel(language.text("cleaner.sort"))
    }

    /// Kick off a background pass measuring every identified container so the
    /// size column and size-sort fill in (WQ deferred-measure parity).
    /// Results accumulate on the measuring queue and commit ONCE at
    /// completion — per-app commits used to decode+encode the whole JSON map
    /// and scan the app list O(n) per event on the main thread.
    private func scheduleContainerSizeMeasurement() {
        let targets = apps.filter { !$0.containerPath.isEmpty }
        guard !targets.isEmpty else { return }
        let pathToBundleID = Dictionary(
            targets.map { ($0.containerPath, $0.bundleID) },
            uniquingKeysWith: { first, _ in first }
        )
        DispatchQueue.global(qos: .utility).async {
            var collected: [String: Int64] = [:]
            let collectLock = NSLock()
            ContainerSizeMeter.measureBatch(targets.map(\.containerPath)) { _, path, bytes in
                guard let bytes, bytes > 0, let bundleID = pathToBundleID[path] else { return }
                collectLock.lock()
                collected[bundleID] = bytes
                collectLock.unlock()
            } completion: {
                DispatchQueue.main.async {
                    for (bundleID, bytes) in collected {
                        containerSizes[bundleID] = bytes
                    }
                    containerSizesJSON = encodeSizes(containerSizes)
                }
            }
        }
    }

    private func encodeSizes(_ sizes: [String: Int64]) -> String {
        guard let data = try? JSONEncoder().encode(sizes) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func openInNewTabButton(_ destination: FileBrowserDestination) -> some View {
        Button {
            tabSession.openTab(navigationPath: [destination])
        } label: {
            Label(language.text("browser.open_new_tab"), systemImage: "square.on.square")
        }
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: AppTheme.emptyIconSize, weight: .light))
                .foregroundStyle(.secondary)
            Text(errorMessage ?? language.text("browser.empty"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
            Button(language.text("browser.retry")) { reload(refreshLaunchServices: true) }
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private var searchEmptyView: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: AppTheme.emptyIconSize, weight: .light))
                .foregroundStyle(.secondary)
            Text(language.text("browser.search_empty"))
                .font(.subheadline.weight(.medium))
            Text(language.text("browser.search_apps_empty_message"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func reload(refreshLaunchServices: Bool = false) {
        if refreshLaunchServices {
            ContainerStore.refreshLaunchServicesSnapshot()
        }
        isLoading = true
        isResolving = true
        errorMessage = nil
        let reloadStarted = CFAbsoluteTimeGetCurrent()
        let emptyMessage = language.text("browser.empty")

        // Dedicated-thread diagnostics for this scan (WQ watchdog parity).
        ScanDiagnostics.beginSession(backend: SandboxAccess.backend.rawValue)
        ScanDiagnostics.stage("enumerate")

        // Phase A: publish the LaunchServices catalog immediately. This is the
        // WQ Files 0.8 fast path: no filesystem scan, no 18 MB parse on the
        // main thread, no waiting for MCM.
        let cachedCatalogSnapshot = ContainerStore.cachedLaunchServicesCatalog()
        catalogCreatedAt = cachedCatalogSnapshot?.createdAt
        let cachedCatalogApps = ContainerStore.installedAppsFromCachedCatalog()
        if !cachedCatalogApps.isEmpty {
            let sortedCatalog = cachedCatalogApps.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            apps = sortedCatalog
            unidentifiedApps = []
            isLoading = false
            hasLoaded = true
            log(
                "browser: catalog cache published \(sortedCatalog.count) apps " +
                    "elapsed=\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - reloadStarted))s"
            )
        }

        // Phase B: discover the catalog on first run, then enrich with names,
        // versions and icons without blocking the list.
        DispatchQueue.global(qos: .userInitiated).async {
            var catalogApps = cachedCatalogApps
            let catalogGroup = DispatchGroup()
            let catalogBox = NSLock()
            var discoveredCatalog: [InstalledApp] = []
            if catalogApps.isEmpty {
                // Discover the database in parallel with the API/MCM passes;
                // the first run used to wait for both sequentially.
                catalogGroup.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    let discovered = ContainerStore.installedAppsFromCatalog()
                    catalogBox.lock()
                    discoveredCatalog = discovered
                    catalogBox.unlock()
                    if !discovered.isEmpty {
                        let sortedCatalog = discovered.sorted {
                            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
                        }
                        DispatchQueue.main.async {
                            apps = sortedCatalog
                            unidentifiedApps = []
                            isLoading = false
                            hasLoaded = true
                        }
                        log(
                            "browser: catalog discovered and published \(sortedCatalog.count) apps " +
                                "elapsed=\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - reloadStarted))s"
                        )
                    }
                    catalogGroup.leave()
                }
            }
            let bundleMetadata: [String: ApplicationBundleMetadata] =
                cachedCatalogApps.isEmpty ? ContainerStore.applicationBundleMetadataCatalog() : [:]
            let apiApps = ContainerStore.applyingBundleMetadata(
                to: ContainerStore.installedAppsFromAPI(),
                catalog: bundleMetadata
            )
            if apiApps.isEmpty {
                log("browser: installed-app API unavailable; trying MCM class-2 enumeration...")
            }
            let dynamicIdentifiers = ContainerStore.dynamicAppIdentifiers()
            let mcmApps = ContainerStore.installedAppsFromMCM(
                identifiers: dynamicIdentifiers,
                bundleMetadata: bundleMetadata
            )
            if cachedCatalogApps.isEmpty, (!apiApps.isEmpty || !mcmApps.isEmpty) {
                let preliminary = ContainerDiscoveryMerger.merge(
                    enumerated: [],
                    identified: mcmApps + apiApps,
                    path: { $0.containerPath }
                ).sorted {
                    $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
                }
                if !preliminary.isEmpty {
                    DispatchQueue.main.async {
                        apps = preliminary.filter {
                            ContainerPresentationPolicy.isIdentified(bundleID: $0.bundleID)
                        }
                        unidentifiedApps = preliminary.filter {
                            !ContainerPresentationPolicy.isIdentified(bundleID: $0.bundleID)
                        }
                        isLoading = false
                        hasLoaded = true
                    }
                    log("browser: API/MCM preliminary published \(preliminary.count) apps")
                }
            }

            catalogGroup.wait()
            catalogBox.lock()
            if !discoveredCatalog.isEmpty {
                catalogApps = discoveredCatalog
            }
            catalogBox.unlock()

            let filesystemApps: [InstalledApp]
            if catalogApps.isEmpty {
                let token = ScanToken()
                DispatchQueue.main.async {
                    scanCoordinator.begin(
                        title: language.text("scan.title.apps"),
                        message: language.text("scan.message.apps"),
                        token: token
                    )
                }
                filesystemApps = ContainerStore.containersFromFilesystem(token: token) { done, total in
                    DispatchQueue.main.async {
                        scanCoordinator.update(done: done, total: total)
                    }
                }
                DispatchQueue.main.async {
                    scanCoordinator.finish()
                }
            } else {
                filesystemApps = []
            }
            let baseIdentifiedApps = mcmApps + apiApps
            var result = ContainerDiscoveryMerger.merge(
                enumerated: catalogApps.isEmpty ? filesystemApps : catalogApps,
                identified: catalogApps + baseIdentifiedApps,
                path: { $0.containerPath }
            )
            log(
                "browser: merged catalog=\(catalogApps.count), api=\(apiApps.count), " +
                    "MCM=\(mcmApps.count), filesystem=\(filesystemApps.count) -> \(result.count)"
            )
            result.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

            let preliminaryIdentified = result.filter {
                ContainerPresentationPolicy.isIdentified(bundleID: $0.bundleID)
            }
            let preliminaryUnidentified = result.filter {
                !ContainerPresentationPolicy.isIdentified(bundleID: $0.bundleID)
            }
            DispatchQueue.main.async {
                apps = preliminaryIdentified
                unidentifiedApps = preliminaryUnidentified
                isLoading = false
            }

            let launchServicesIdentifiers: [String] = catalogApps.isEmpty
                ? ContainerStore.launchServicesStoreIdentifiers()
                : Array(Set(catalogApps.map(\.bundleID)))
            let resolvedContainerCount = filesystemApps.reduce(0) { count, app in
                count + (UUID(uuidString: app.bundleID) == nil ? 1 : 0)
            }
            // The LaunchServices snapshot already names almost every
            // filesystem container. The MHA-C2 pass activates each candidate
            // through MCM and costs several seconds; only run it when the
            // filesystem list is mostly unidentified.
            let shouldScanMHA = catalogApps.isEmpty && (filesystemApps.isEmpty
                || resolvedContainerCount * 4 < filesystemApps.count * 3)
            var mhaApps: [InstalledApp] = []
            if shouldScanMHA {
                let mhaIdentifiers = MHAIdentifierCatalog.identifiers(
                    dynamic: dynamicIdentifiers,
                    installed: apiApps.map(\.bundleID),
                    research: ContainerStore.researchAppIdentifiers,
                    custom: bundleMetadata.keys.sorted(),
                    launchServices: launchServicesIdentifiers
                )
                log(
                    "browser: MHA catalog dynamic=\(dynamicIdentifiers.count), " +
                    "installed=\(apiApps.count), research=\(ContainerStore.researchAppIdentifiers.count), " +
                    "LaunchServices=\(launchServicesIdentifiers.count) -> \(mhaIdentifiers.count) candidates"
                )
                mhaApps = ContainerStore.installedAppsFromMHACandidates(
                    identifiers: mhaIdentifiers,
                    bundleMetadata: bundleMetadata
                ) { discoveredApps in
                    // Keep the filesystem fallback in the progressive result:
                    // replacing the list with identified-only entries made the
                    // browser visibly shrink while the MHA scan was running.
                    var progressiveResult = AppDataCatalogMerger.merge(
                        identified: discoveredApps + baseIdentifiedApps + catalogApps,
                        fallback: filesystemApps,
                        identifier: { $0.bundleID },
                        path: { $0.containerPath }
                    )
                    progressiveResult.sort {
                        $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
                    }
                    let identified = progressiveResult.filter {
                        ContainerPresentationPolicy.isIdentified(bundleID: $0.bundleID)
                    }
                    let unidentified = progressiveResult.filter {
                        !ContainerPresentationPolicy.isIdentified(bundleID: $0.bundleID)
                    }
                    DispatchQueue.main.async {
                        apps = identified
                        unidentifiedApps = unidentified
                    }
                }
            } else {
                log(
                    "browser: skipping MHA scan — filesystem resolved " +
                        "\(resolvedContainerCount)/\(filesystemApps.count) containers"
                )
            }

            let allKnownApps = mhaApps + baseIdentifiedApps + catalogApps
            let identifiedPaths = Set(allKnownApps.map {
                ContainerDiscoveryMerger.canonicalPath($0.containerPath)
            })
            let unmatchedFilesystemApps = filesystemApps.filter {
                !identifiedPaths.contains(
                    ContainerDiscoveryMerger.canonicalPath($0.containerPath)
                )
            }
            let inferredFilesystemApps = ContainerStore.inferUnidentifiedApps(
                in: unmatchedFilesystemApps,
                knownApps: allKnownApps,
                launchServicesIdentifiers: Set(launchServicesIdentifiers)
            )
            result = AppDataCatalogMerger.merge(
                identified: allKnownApps,
                fallback: inferredFilesystemApps,
                identifier: { $0.bundleID },
                path: { $0.containerPath }
            )
            result.sort {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            let identified = result.filter {
                ContainerPresentationPolicy.isIdentified(bundleID: $0.bundleID)
            }
            let unidentified = result.filter {
                !ContainerPresentationPolicy.isIdentified(bundleID: $0.bundleID)
            }

            DispatchQueue.main.async {
                apps = identified
                unidentifiedApps = unidentified
                isLoading = false
                isResolving = false
                if result.isEmpty {
                    errorMessage = emptyMessage
                }
                log(
                    "browser: app data ready apps=\(identified.count + unidentified.count) " +
                        "elapsed=\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - reloadStarted))s"
                )
                ScanDiagnostics.endSession(
                    summary: "apps=\(identified.count + unidentified.count) " +
                        "elapsed=\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - reloadStarted))s"
                )
            }
        }
    }
}

private enum AppBrowserOverlayState: Equatable {
    case loading
    case empty
    case noResults
    case none
}

struct BrowserAppIcon: View {
    let app: InstalledApp
    @State private var resolvedIcon: UIImage?
    @State private var didRequestIcon = false

    init(app: InstalledApp) {
        self.app = app
        _resolvedIcon = State(initialValue: app.icon)
    }

    var body: some View {
        Group {
            if let resolvedIcon {
                Image(uiImage: resolvedIcon)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "app")
                    .font(.system(size: AppTheme.rowIconSize, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: AppTheme.appIconSize, height: AppTheme.appIconSize)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityHidden(true)
        .onAppear {
            guard resolvedIcon == nil, !didRequestIcon else { return }
            didRequestIcon = true
            let bundleID = app.bundleID
            DispatchQueue.global(qos: .utility).async {
                let icon = iconForBundleID(bundleID)
                DispatchQueue.main.async {
                    resolvedIcon = icon
                }
            }
        }
    }
}
