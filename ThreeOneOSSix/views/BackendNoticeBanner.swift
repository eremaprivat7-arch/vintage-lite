import SwiftUI

/// Red inline banner shown on top of features that require the worse_query
/// backend's SystemGroup reach (MobileGestalt cache, ConfigurationProfiles,
/// …). On iOS 26.0–26.6.1 the bad_query backend covers app/daemon/group
/// containers only, so these pages would otherwise present enabled buttons
/// that all fail at write time — the banner names the reason up front,
/// per the operator's requirement (red text inside the feature menu).
struct BackendNoticeBanner: View {
    @Environment(\.appLanguage) private var language
    /// Feature-specific unavailability copy key; the generic default explains
    /// the backend split. Shown only when the backend cannot serve the page.
    var unavailableKey: String = "backend.notice.system_group"

    var body: some View {
        if SandboxAccess.systemGroupFeaturesUnavailable {
            VStack(alignment: .leading, spacing: 6) {
                Label(language.text("backend.notice.title"), systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.red)
                Text(language.text(unavailableKey))
                    .font(.footnote)
                    .foregroundStyle(.red.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.red.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.red.opacity(0.35), lineWidth: 0.8)
            )
            .accessibilityElement(children: .combine)
        }
    }
}
