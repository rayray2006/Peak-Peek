import SwiftUI

/// Scrub the date + time of day to drive the sun, moon, stars and Milky Way.
/// Terrain shading is fixed/baked, so this re-lights only the sky overlay.
/// (Adapted from RidgeLine's TimePanel.)
struct TimeControlsView: View {
    @ObservedObject var model: PanoramaViewModel
    @Environment(\.dismiss) private var dismiss

    /// Everything here is expressed in the VIEWED location's timezone (offline, from
    /// its longitude), so "noon" on the slider is noon where you're standing and the
    /// clock matches the rise/set tags — not the device's zone.
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = model.displayTimeZone
        return c
    }
    private var timeFormatter: DateFormatter {
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none
        f.timeZone = model.displayTimeZone
        return f
    }

    /// DatePicker (.date) preserves the time component, so passing it straight
    /// through only changes the day.
    private var dateBinding: Binding<Date> {
        Binding(get: { model.displayDate }, set: { model.setDisplayDate($0) })
    }
    /// Slider drives seconds-into-day on the currently selected day.
    private var secondsBinding: Binding<Double> {
        Binding(
            get: { secondsIntoDay(model.displayDate) },
            set: { model.setDisplayDate(date(onSameDayAs: model.displayDate, secondsIntoDay: $0)) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            datePickerCard
            timeSlider
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Size the sheet to just the content (no empty space) so it covers as little
        // of the sky as possible while scrubbing.
        .presentationDetents([.height(280)])
        .presentationDragIndicator(.visible)
        // Colour the WHOLE sheet (incl. the safe-area strips + rounded corners); a
        // plain `.background` only tints the content and leaves the sheet's default
        // black chrome showing as bars top & bottom.
        .presentationBackground(Color(TopoStyle.background))
        // Don't dim the sky behind the menu — let the live sky stay bright (and
        // interactive) while scrubbing time.
        .presentationBackgroundInteraction(.enabled(upThrough: .height(280)))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(model.usesSimulatedTime ? Color.orange : .white.opacity(0.9))
            VStack(alignment: .leading, spacing: 2) {
                Text("Time").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                Text(model.usesSimulatedTime ? "Simulated sky" : "Live sky")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            // (Reset-to-now lives in the fixed top-left controls, next to
            // Use GPS / Realign — not in this sheet.)
        }
    }

    private var datePickerCard: some View {
        HStack {
            Text("Date").font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.85))
            Spacer()
            DatePicker("", selection: dateBinding, displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.compact)
                .environment(\.timeZone, model.displayTimeZone)
                .tint(Color(TopoStyle.accent))
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    private var timeSlider: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Time of day").font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                Spacer()
                Text(timeFormatter.string(from: model.displayDate))
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
            }
            Slider(value: secondsBinding, in: 0...86_399, step: 60)
                .tint(Color(TopoStyle.accent))
            tickLabels
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    private var tickLabels: some View {
        HStack(spacing: 0) {
            ForEach(Array(["12 AM", "6 AM", "Noon", "6 PM", "12 AM"].enumerated()), id: \.offset) { idx, label in
                Text(label)
                if idx < 4 { Spacer() }
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(.white.opacity(0.45))
    }

    // MARK: - Date math

    private func secondsIntoDay(_ date: Date) -> Double {
        let c = calendar.dateComponents([.hour, .minute, .second], from: date)
        let h: Int = c.hour ?? 0
        let m: Int = c.minute ?? 0
        let s: Int = c.second ?? 0
        return Double(h * 3600 + m * 60 + s)
    }

    private func date(onSameDayAs date: Date, secondsIntoDay seconds: Double) -> Date {
        calendar.startOfDay(for: date).addingTimeInterval(seconds)
    }
}
