import SwiftUI

/// The "Data & licenses" content shown inside the Info card (RootScreen) —
/// tucked one tap behind the how-to tips. Together with the elevation line in
/// the region manager's footer, this satisfies every attribution the bundled
/// data requires: OpenStreetMap (ODbL — required, user-visible), GeoNames
/// (CC BY), the HYG star catalog (CC BY-SA), Copernicus (ESA licence), and
/// the SIL OFL text that must accompany the bundled fonts.
struct DataCreditsContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            creditRow("Peaks, passes & lakes",
                      "© OpenStreetMap contributors, licensed ODbL — openstreetmap.org/copyright. Additional records from GeoNames (geonames.org, CC BY 4.0).")
            creditRow("Elevation",
                      "Copernicus GLO-30 DEM © ESA / DLR · NASA SRTM, served from the Mapzen terrain tiles on AWS Open Data · Far horizon from NOAA ETOPO1.")
            creditRow("Stars",
                      "HYG stellar database, astronexus.com (CC BY-SA).")
            creditRow("Map imagery",
                      "Apple Maps — see Legal on the map views.")
            creditRow("Type",
                      "Space Grotesk (Florian Karsten) and IBM Plex Mono (IBM), both under the SIL Open Font License 1.1:")
            Text(Self.fontLicenses)
                .font(PPFont.mono(9))
                .foregroundStyle(TopoStyle.inkColor.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.trailing, 4)
    }

    private func creditRow(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(PPFont.ui(13, .semibold))
                .foregroundStyle(TopoStyle.inkColor)
            Text(body)
                .font(PPFont.ui(12))
                .foregroundStyle(TopoStyle.inkColor.opacity(0.62))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Both fonts' OFL notices + license text (bundled verbatim — the OFL
    /// requires the license accompany the font software it covers).
    private static let fontLicenses: String = {
        guard let url = Bundle.main.url(forResource: "font-licenses", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "SIL Open Font License 1.1 — scripts.sil.org/OFL"
        }
        return text
    }()
}
