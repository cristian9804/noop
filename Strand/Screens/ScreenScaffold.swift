import SwiftUI
import StrandDesign

/// Standard scrollable screen container: title + dark surface + content column.
struct ScreenScaffold<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(StrandFont.title1).foregroundStyle(StrandPalette.textPrimary)
                    if let subtitle {
                        Text(subtitle).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                content()
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(StrandPalette.surfaceBase)
    }
}

/// Placeholder body for screens the design agents are still building.
struct ComingSoon: View {
    let what: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Coming together")
                .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
            Text(what)
                .font(StrandFont.body).foregroundStyle(StrandPalette.textSecondary)
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 14))
    }
}
