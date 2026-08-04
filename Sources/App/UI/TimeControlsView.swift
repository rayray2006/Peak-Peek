import SwiftUI

/// Scrub the date + time of day to drive the sun, moon, stars and Milky Way.
/// Terrain shading is fixed/baked, so this re-lights only the sky overlay.
///
/// Faithful to the template's Time sheet: a bordered date button that folds a
/// mono calendar grid open, "6:42 PM / now" readout, a 1 px hairline scrubber
/// with a white circle thumb over "12 AM · Noon · 11 PM" ticks, and the
/// sunrise/sunset facts as a HORIZON / VISIBLE grid table. One layout for
/// both orientations (the template's landscape card is the same stack,
/// narrower); the hosting PanelCard supplies the sheet chrome + title.
struct TimeControlsView: View {
    @ObservedObject var model: PanoramaViewModel
    /// Landscape: identical content in a narrower, height-capped scroll.
    var compact = false
    @Environment(\.dismiss) private var dismiss
    /// Observed only so the clock (and rise/set times) re-render the instant the
    /// menu's 12/24h toggle flips; the formatter reads the value via ClockText.
    @AppStorage(ClockText.overrideKey) private var clockOverride = ""

    /// Everything here is expressed in the VIEWED location's timezone (offline, from
    /// its longitude), so "noon" on the slider is noon where you're standing and the
    /// clock matches the rise/set tags — not the device's zone.
    ///
    /// The formatters and calendar are SHARED statics (main-thread only, like all
    /// of SwiftUI body): constructing a DateFormatter is one of the classically
    /// expensive Foundation inits, and body re-evaluates on every scrub tick —
    /// only the timezone ever differs.
    private static let gregorian = Calendar(identifier: .gregorian)
    private static let sharedTimeFormatter: DateFormatter = {
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none
        return f
    }()
    private static let sharedDateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE, MMM d"
        return f
    }()
    private static let sharedMonthFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMMM yyyy"
        return f
    }()

    private var calendar: Calendar {
        var c = Self.gregorian
        c.timeZone = model.displayTimeZone
        return c
    }
    private var timeFormatter: DateFormatter {
        let f = Self.sharedTimeFormatter
        f.timeZone = model.displayTimeZone
        ClockText.applyTimeStyle(to: f)   // 12/24h per the menu override or locale
        return f
    }
    private var dateFormatter: DateFormatter {
        let f = Self.sharedDateFormatter
        f.timeZone = model.displayTimeZone
        return f
    }
    private var monthFormatter: DateFormatter {
        let f = Self.sharedMonthFormatter
        f.timeZone = model.displayTimeZone
        return f
    }

    /// Slider drives seconds-into-day on the currently selected day.
    private var secondsBinding: Binding<Double> {
        Binding(
            get: { secondsIntoDay(model.displayDate) },
            set: { model.setDisplayDate(date(onSameDayAs: model.displayDate, secondsIntoDay: $0)) }
        )
    }

    /// The template's date button expands the calendar grid underneath.
    @State private var calendarOpen = false

    var body: some View {
        let stack = VStack(alignment: .leading, spacing: 12) {
            dateButton
            if calendarOpen {
                // Fade while the (transaction-animated) layout makes room /
                // reclaims it — see the dateButton action for why the
                // animation lives on the toggle, not here.
                calendarGrid
                    .transition(.opacity)
            }
            timeReadout
            scrubber
            tickLabels
            sunGrid
                .padding(.top, 6)
        }
        .padding(.horizontal, 20)
        .padding(.top, 2)
        .padding(.bottom, compact ? 14 : 22)

        Group {
            if compact {
                // Hug the content when it fits the short axis (a fixed-height
                // scroll left a blank band under the sun table); scroll only
                // when it genuinely doesn't (calendar open).
                ViewThatFits(in: .vertical) {
                    stack
                    ScrollView { stack }
                        .frame(maxHeight: 300)
                }
            } else {
                stack
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // (No presentation modifiers: this view is hosted only inside the inline
        // PanelCard, never as a sheet.)
    }

    // MARK: - Date button + calendar

    /// Bordered, centered "📅 Wed, Jul 16" field, exactly the template's.
    private var dateButton: some View {
        Button {
            // withAnimation (not .animation(value:) on the stack): the sheet's
            // HEIGHT lives in the hosting PanelCard, outside this view — a
            // local animation modifier can't reach it, so the card snapped
            // shut while the grid faded (the jerky collapse). A transaction
            // animates every layout affected by the toggle, card included.
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                calendarOpen.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                    .font(.system(size: 14, weight: .regular))
                Text(dateFormatter.string(from: model.displayDate))
                    .font(PPFont.ui(15, .semibold))
            }
            .foregroundStyle(TopoStyle.inkColor)
            .frame(maxWidth: .infinity)
            .frame(height: compact ? 38 : 40)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(TopoStyle.hairline(0.18), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The template's calendar: mono month label, S M T W T F S header,
    /// 26 pt circle days — selected day inverts to ink. Small chevrons page
    /// months (the mock's grid shows a single month).
    private var calendarGrid: some View {
        let cal = calendar
        let monthStart = cal.dateInterval(of: .month, for: model.displayDate)?.start ?? model.displayDate
        let dayCount = cal.range(of: .day, in: .month, for: model.displayDate)?.count ?? 30
        let leadingBlanks = (cal.component(.weekday, from: monthStart) - cal.firstWeekday + 7) % 7
        let selectedDay = cal.component(.day, from: model.displayDate)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(monthFormatter.string(from: model.displayDate).uppercased())
                    .font(PPFont.mono(11))
                    .tracking(1.5)
                    .foregroundStyle(TopoStyle.inkColor.opacity(0.55))
                Spacer()
                monthChevron("chevron.left", by: -1)
                monthChevron("chevron.right", by: 1)
            }
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(Array("SMTWTFS".enumerated()), id: \.offset) { _, c in
                    Text(String(c))
                        .font(PPFont.mono(9))
                        .foregroundStyle(TopoStyle.inkColor.opacity(0.4))
                }
                ForEach(0..<leadingBlanks, id: \.self) { _ in
                    Color.clear.frame(height: 26)
                }
                ForEach(1...dayCount, id: \.self) { day in
                    let selected = day == selectedDay
                    Button {
                        selectDay(day)
                    } label: {
                        Text("\(day)")
                            .font(PPFont.mono(11))
                            .foregroundStyle(selected ? TopoStyle.paperColor : TopoStyle.inkColor)
                            .frame(maxWidth: .infinity)
                            .frame(height: 26)
                            .background {
                                if selected { Circle().fill(TopoStyle.inkColor) }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(TopoStyle.hairline(0.10), lineWidth: 1)
        )
        // Horizontal swipe pages months, matching the chevrons: left → next,
        // right → previous. HORIZONTAL only (25 pt, dominant axis) — vertical
        // drags stay with the hosting ScrollView, and day taps are unaffected.
        .gesture(
            DragGesture(minimumDistance: 25)
                .onEnded { v in
                    let dx = v.translation.width, dy = v.translation.height
                    guard abs(dx) > abs(dy) else { return }
                    if let d = calendar.date(byAdding: .month, value: dx < 0 ? 1 : -1,
                                             to: model.displayDate) {
                        model.setDisplayDate(d)
                    }
                }
        )
    }

    private func monthChevron(_ systemName: String, by months: Int) -> some View {
        Button {
            if let d = calendar.date(byAdding: .month, value: months, to: model.displayDate) {
                model.setDisplayDate(d)
            }
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(TopoStyle.inkColor.opacity(0.55))
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Same month + time of day, new day number.
    private func selectDay(_ day: Int) {
        let cal = calendar
        var comps = cal.dateComponents([.year, .month], from: model.displayDate)
        comps.day = day
        guard let dayStart = cal.date(from: comps) else { return }
        model.setDisplayDate(dayStart.addingTimeInterval(secondsIntoDay(model.displayDate)))
    }

    // MARK: - Time readout + scrubber

    /// The viewed location's zone code ("PDT", "CEST", "GMT+5:30"), shown ONLY
    /// when its clock actually differs from the device's — every time on the
    /// card is in the PIN-DROP location's zone, and without the code a remote
    /// viewpoint's times read as nonsense against the user's own clock.
    private var timeZoneCode: String? {
        let tz = model.displayTimeZone
        guard tz.secondsFromGMT(for: model.displayDate)
            != TimeZone.current.secondsFromGMT(for: model.displayDate) else { return nil }
        return tz.abbreviation(for: model.displayDate)
    }

    /// "6:42 PM        now" — the current scrub position, baseline-aligned.
    private var timeReadout: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(timeFormatter.string(from: model.displayDate))
                .font(PPFont.ui(15, .semibold))
                .foregroundStyle(TopoStyle.inkColor)
            if let code = timeZoneCode {
                Text(code)
                    .font(PPFont.mono(10))
                    .foregroundStyle(TopoStyle.inkColor.opacity(0.45))
            }
            Spacer()
            Text(model.usesSimulatedTime ? "simulated" : "now")
                .font(PPFont.mono(11))
                .foregroundStyle(TopoStyle.inkColor.opacity(0.5))
        }
    }

    /// The template's scrubber: a full-width 1 px hairline with a 16 pt white
    /// circle thumb (1.5 px ink ring) riding it. No fill, no system slider.
    private var scrubber: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let frac = CGFloat(min(1, max(0, secondsBinding.wrappedValue / 86_399)))
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(TopoStyle.hairline(0.14))
                    .frame(height: 1)
                Circle()
                    .fill(.white)
                    .overlay(Circle().strokeBorder(TopoStyle.inkColor, lineWidth: 1.5))
                    .frame(width: 16, height: 16)
                    .offset(x: frac * max(0, w - 16))
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let f = min(1, max(0, (g.location.x - 8) / max(1, w - 16)))
                        // Snap to whole minutes, like the old slider's step.
                        let seconds = (f * 86_399 / 60).rounded() * 60
                        secondsBinding.wrappedValue = Double(seconds)
                    }
            )
        }
        .frame(height: 24)
    }

    private var tickLabels: some View {
        HStack {
            Text("12 AM")
            Spacer()
            Text("Noon")
            Spacer()
            Text("11 PM")
        }
        .font(PPFont.mono(10))
        .foregroundStyle(TopoStyle.inkColor.opacity(0.4))
    }

    // MARK: - Sun facts (the template's HORIZON / VISIBLE grid)

    private func timeText(_ date: Date?) -> String {
        date.map { timeFormatter.string(from: $0) } ?? "—"
    }

    /// ```
    ///            HORIZON    VISIBLE
    /// Sunrise    5:24 AM    6:02 AM
    /// Sunset     8:58 PM    8:12 PM
    /// ```
    /// HORIZON = true rise/set at the sea-level horizon; VISIBLE = when the
    /// sun actually clears / drops behind the terrain ridge at this viewpoint.
    /// "—" until the renderer's celestial pass lands (or when the sun never
    /// crosses, e.g. polar day/night).
    private var sunGrid: some View {
        let sun = model.sunTimes
        return Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
            GridRow {
                Color.clear
                    .gridCellUnsizedAxes([.horizontal, .vertical])
                    .frame(maxWidth: .infinity)
                gridHeader("Horizon")
                gridHeader("Visible")
            }
            GridRow {
                gridLabel("Sunrise")
                gridTime(timeText(sun?.sunrise))
                gridTime(timeText(sun?.firstVisible))
            }
            GridRow {
                gridLabel("Sunset")
                gridTime(timeText(sun?.sunset))
                gridTime(timeText(sun?.lastVisible))
            }
        }
    }

    private func gridHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(PPFont.mono(10))
            .tracking(1.2)
            .foregroundStyle(TopoStyle.inkColor.opacity(0.45))
    }

    private func gridLabel(_ text: String) -> some View {
        Text(text)
            .font(PPFont.ui(14, .medium))
            .foregroundStyle(TopoStyle.inkColor)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func gridTime(_ text: String) -> some View {
        Text(text)
            .font(PPFont.mono(12))
            .foregroundStyle(TopoStyle.inkColor)
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
