import Foundation

/// The container-access backend selected for the running OS.
///
/// - `kernel`: iOS 17/18 kernel exploit chain (unchanged from 3105).
/// - `badQuery`: the original bad_query grant for iOS 26.0–26.6.1.
/// - `worseQuery`: worse_query sandbox escape for iOS 26.7+ and 27.x.
enum SandboxBackend: String {
    case kernel
    case badQuery
    case worseQuery
    case unsupported

    var displayName: String {
        switch self {
        case .kernel: return "kernel"
        case .badQuery: return "bad_query"
        case .worseQuery: return "worse_query"
        case .unsupported: return "unsupported"
        }
    }
}

/// One place for every sandbox grant. Callers keep treating the return value as
/// an opaque `Int64` handle, so the rest of the app did not need to change.
enum SandboxAccess {
    static var backend: SandboxBackend {
        let v = AppInfo.versionTuple
        if ExploitSupportPolicy.supportsKernelExploit(major: v.major, minor: v.minor, patch: v.patch) {
            return .kernel
        }
        if ExploitSupportPolicy.supportsWorseQuery(major: v.major, minor: v.minor, patch: v.patch) ||
            ExploitSupportPolicy.isExperimental(major: v.major, minor: v.minor) {
            return .worseQuery
        }
        if ExploitSupportPolicy.supportsBadQuery(major: v.major, minor: v.minor, patch: v.patch) {
            return .badQuery
        }
        return .unsupported
    }

    static var appGroup: String? {
        worse_query_app_group()
    }

    static var hasAppGroup: Bool { appGroup != nil }

    static var needsWorseQuery: Bool { backend == .worseQuery }

    /// System Data and System Groups are only reachable through worse_query on
    /// iOS 27; iOS 26 (either backend) and the kernel path keep their old
    /// visibility rules.
    static var systemAreasReachable: Bool {
        switch backend {
        case .kernel, .badQuery:
            return true
        case .worseQuery:
            return AppInfo.versionTuple.major >= 27
        case .unsupported:
            return false
        }
    }

    /// True when the current backend can reach Shared/SystemGroup containers
    /// (MobileGestalt cache, ConfigurationProfiles → Supervised Mode, …).
    /// Only worse_query grants those on iOS 26.7+; the bad_query backend
    /// (iOS 26.0–26.6.1) covers app/daemon/group containers only, and the
    /// kernel backend reaches whatever the kernel permits but historically
    /// the 3105 lineage used it without SystemGroup writes.
    static var systemGroupWritable: Bool {
        // kernel (iOS 17/18) escapes the sandbox entirely and reaches system
        // groups; worse_query grants them on 26.7+/27. Only bad_query
        // (26.0-26.6.1) cannot.
        backend == .worseQuery || backend == .kernel
    }

    /// True when worse_query's App-Group technique is REQUIRED but the
    /// device cannot run it (e.g. iOS 26.0–26.6.1 on bad_query, or a
    /// missing App Group entitlement).
    static var systemGroupFeaturesUnavailable: Bool {
        !systemGroupWritable
    }

    /// System Groups' parent cannot be listed on 27.0.1; callers fall back to
    /// probing known container names.
    static var systemGroupParentListable: Bool {
        let v = AppInfo.versionTuple
        return !(v.major == 27 && v.minor == 0 && v.patch == 1)
    }

    /// Heals an interrupted Caches swap. Called once at launch.
    static func prepare() {
        guard backend == .worseQuery else { return }
        if !worse_query_recover() {
            log("sandbox: worse_query recovery skipped or needs attention")
        }
    }

    /// A lightweight activation probe used by the UI. It verifies the App Group
    /// exists for worse_query, and that the previous grant path is usable for
    /// bad_query.
    static func probe() -> Bool {
        switch backend {
        case .kernel:
            return KernelExploit.hasKernelSandboxAccess()
        case .badQuery:
            let handle = grant(path: ContainerStore.appDataRoot)
            if handle >= 0 {
                release(handle)
                return true
            }
            return false
        case .worseQuery:
            guard let group = appGroup,
                  let groupURL = FileManager.default.containerURL(
                    forSecurityApplicationGroupIdentifier: group
                  ) else {
                log("sandbox: no App Group entitlement — worse_query cannot run")
                return false
            }
            // Exercise the real query path on our own group container first;
            // the parent container root is not grantable on every iOS 26 build.
            if grant(path: groupURL.path) >= 0 {
                return true
            }
            let handle = grant(path: ContainerStore.appDataRoot)
            if handle >= 0 {
                return true
            }
            log("sandbox: worse_query probe failed on the App Group and app-data root")
            return false
        case .unsupported:
            return false
        }
    }

    static func grant(path: String) -> Int64 {
        let clean = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        switch backend {
        case .kernel:
            return -1
        case .badQuery:
            var pathC = clean.utf8CString.map { Int8($0) }
            return bad_query(&pathC, true, nil, false)
        case .worseQuery:
            var pathC = clean.utf8CString.map { Int8($0) }
            return worse_query_grant(&pathC)
        case .unsupported:
            return -1
        }
    }

    static func release(_ handle: Int64) {
        guard handle >= 0 else { return }
        switch backend {
        case .kernel:
            break
        case .badQuery:
            bad_query_release(handle)
        case .worseQuery:
            worse_query_release(handle)
        case .unsupported:
            break
        }
    }
}