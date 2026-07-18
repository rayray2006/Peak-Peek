import Foundation

/// Persisted "Been" / "Saved" feature lists. (Ported from RidgeLine.)
/// The case names are the persisted rawValues (regions.json-era manifests) —
/// they keep their historical spelling; only the TITLES say Been/Saved.
enum PeakListKind: String, CaseIterable, Codable, Identifiable {
    case climbed
    case wantToClimb

    var id: String { rawValue }

    var title: String {
        switch self {
        case .climbed: return "Been"
        case .wantToClimb: return "Saved"
        }
    }

    var systemImage: String {
        switch self {
        case .climbed: return "checkmark.seal.fill"
        case .wantToClimb: return "bookmark.fill"
        }
    }
}

struct SavedPeak: Identifiable, Codable, Hashable {
    var peak: Peak
    var climbedAt: Date?
    var wantToClimbAt: Date?

    var id: String { peak.id }

    func date(for kind: PeakListKind) -> Date? {
        switch kind {
        case .climbed: return climbedAt
        case .wantToClimb: return wantToClimbAt
        }
    }
}

@MainActor
final class PeakListStore: ObservableObject {
    @Published private var saved: [String: SavedPeak] = [:] {
        didSet {
            persist()
            recomputeIDSets()
        }
    }

    /// Memoized membership sets for the render path: RootScreen hands these to
    /// the Metal view on every body evaluation, so rebuilding them from a full
    /// list scan per render was pure churn.
    private(set) var climbedIDs: Set<String> = []
    private(set) var bookmarkedIDs: Set<String> = []

    private func recomputeIDSets() {
        climbedIDs = Set(saved.values.compactMap { $0.climbedAt != nil ? $0.id : nil })
        bookmarkedIDs = Set(saved.values.compactMap { $0.wantToClimbAt != nil ? $0.id : nil })
    }

    private let defaults: UserDefaults
    // Historical key from before the PeakPeek rename — changing it would
    // silently orphan everyone's saved climbed/bookmarked lists.
    private let key = "com.mountainView.peakLists.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: SavedPeak].self, from: data) {
            saved = decoded
        }
        recomputeIDSets()
    }

    func contains(_ peak: Peak, in kind: PeakListKind) -> Bool {
        saved[peak.id]?.date(for: kind) != nil
    }

    func toggle(_ peak: Peak, in kind: PeakListKind) {
        var entry = saved[peak.id] ?? SavedPeak(peak: peak, climbedAt: nil, wantToClimbAt: nil)
        entry.peak = peak
        let now = Date()
        switch kind {
        case .climbed:
            entry.climbedAt = entry.climbedAt == nil ? now : nil
        case .wantToClimb:
            entry.wantToClimbAt = entry.wantToClimbAt == nil ? now : nil
        }
        if entry.climbedAt == nil && entry.wantToClimbAt == nil {
            saved.removeValue(forKey: peak.id)
        } else {
            saved[peak.id] = entry
        }
    }

    func remove(_ peak: Peak, from kind: PeakListKind) {
        guard var entry = saved[peak.id] else { return }
        switch kind {
        case .climbed: entry.climbedAt = nil
        case .wantToClimb: entry.wantToClimbAt = nil
        }
        if entry.climbedAt == nil && entry.wantToClimbAt == nil {
            saved.removeValue(forKey: peak.id)
        } else {
            saved[peak.id] = entry
        }
    }

    func peaks(in kind: PeakListKind) -> [SavedPeak] {
        saved.values
            .filter { $0.date(for: kind) != nil }
            .sorted { ($0.date(for: kind) ?? .distantPast) > ($1.date(for: kind) ?? .distantPast) }
    }

    func count(in kind: PeakListKind) -> Int {
        switch kind {
        case .climbed: return climbedIDs.count
        case .wantToClimb: return bookmarkedIDs.count
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(saved) else { return }
        defaults.set(data, forKey: key)
    }
}
