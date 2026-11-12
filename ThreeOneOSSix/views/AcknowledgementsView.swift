import SwiftUI

struct AcknowledgementsView: View {
    @Environment(\.appLanguage) private var language

    private struct Credit: Identifiable {
        let id = UUID()
        let name: String
        let detailKey: String
        let url: URL
    }

    private var credits: [Credit] {
        [
            Credit(
                name: "WQ Files / kolbicz",
                detailKey: "ack.wqfiles",
                url: URL(string: "https://github.com/kolbicz/WQFiles")!
            ),
            Credit(
                name: "Erosion / jailbreak.party",
                detailKey: "ack.erosion",
                url: URL(string: "https://github.com/jailbreakdotparty/Erosion")!
            ),
            Credit(
                name: "worse_query / forcequitOS",
                detailKey: "ack.worse_query",
                url: URL(string: "https://github.com/forcequitOS/worse_query")!
            ),
            Credit(
                name: "3105 / YangJiiii",
                detailKey: "ack.3105",
                url: URL(string: "https://github.com/YangJiiii/3105")!
            ),
            Credit(
                name: "GestaltX / huamidev",
                detailKey: "ack.gestaltx",
                url: URL(string: "https://github.com/huamidev/GestaltX")!
            ),
            Credit(
                name: "YumEdit / H4CNPE",
                detailKey: "ack.yumedit",
                url: URL(string: "https://github.com/H4CNPE/YumEdit")!
            ),
            Credit(
                name: "Erosion-CN / Kianuni",
                detailKey: "ack.erosion_cn",
                url: URL(string: "https://github.com/Kianuni/Erosion-CN")!
            ),
            Credit(
                name: "WQManager / hseons",
                detailKey: "ack.wqmanager",
                url: URL(string: "https://github.com/hseons/WQManager")!
            ),
            Credit(
                name: "AltGallery / bebound",
                detailKey: "ack.altgallery",
                url: URL(string: "https://github.com/bebound/AltGallery")!
            ),
        ]
    }

    var body: some View {
        List {
            Section {
                Text(language.text("ack.footer"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section(language.text("ack.credits")) {
                ForEach(credits) { credit in
                    Link(destination: credit.url) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(credit.name)
                                .font(.subheadline.weight(.medium))
                            Text(language.text(credit.detailKey))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            Section(language.text("ack.license")) {
                Text("GPL-3.0-or-later")
                    .font(.footnote.monospaced())
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(language.text("ack.title"))
        .navigationBarTitleDisplayMode(.inline)
    }
}