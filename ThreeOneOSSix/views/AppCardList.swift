import SwiftUI

/// Shared app-card row (WQManager AppCardCell parity): icon + headline title
/// + monospaced 10pt secondary line (`bundleID · size`, middle-truncated).
/// Used by the file browser, cleaner, search and patch lists so every app
/// list reads the same.
struct AppCardRow<Icon: View>: View {
    let title: String
    let subtitle: String?
    let statusText: String?
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        HStack(spacing: 12) {
            icon()
                .frame(width: AppTheme.appIconSize, height: AppTheme.appIconSize)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.appIconSize * 0.22, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 8)

            if let statusText, !statusText.isEmpty {
                Text(statusText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Convenience for the common case: an app icon image (or fallback symbol).
struct AppCardRowIcon: View {
    let image: UIImage?
    let fallbackSymbol: String

    init(image: UIImage?, fallbackSymbol: String = "app") {
        self.image = image
        self.fallbackSymbol = fallbackSymbol
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: AppTheme.appIconSize * 0.22, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemFill))
                    Image(systemName: fallbackSymbol)
                        .font(.system(size: AppTheme.appIconSize * 0.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: AppTheme.appIconSize, height: AppTheme.appIconSize)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.appIconSize * 0.22, style: .continuous))
        .accessibilityHidden(true)
    }
}
