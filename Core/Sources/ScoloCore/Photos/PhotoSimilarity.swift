import Foundation

/// How alike two photographs must look before the similar tier calls them the same.
///
/// This exists because the one threshold that shipped was wrong for at least one
/// real library: different screenshots were grouped together. That is not a bug in
/// the clustering — two screenshots of the same app genuinely are close in Vision's
/// feature space, sharing their chrome, their palette and their proportions — it is
/// a threshold doing a job no single number can do for every library. So the number
/// is the user's.
///
/// The scale is the **Euclidean distance between two Vision feature prints**,
/// revision 2, 768 dimensions. Lower is more alike; zero is the same image.
/// `DuplicateGroup.maximumDistance` puts the measured figure on every similar group,
/// so the setting can be read against what it actually produced rather than guessed
/// at.
///
/// **Only `.standard` has been exercised against a real library** — 11,103
/// photographs, which is where the complete-linkage rule and the 24-hour bucket were
/// measured. The other four are a scale around it, not findings. They are offered
/// because the user can see each group's distance and judge, which is a better
/// authority than a number chosen here.
///
/// The burst and exact tiers are untouched by this. Burst is Apple's own grouping
/// and exact claims certainty from a metadata signature plus agreement within 0.05;
/// neither is a judgement call the user should have to make.
public enum PhotoSimilarity: String, Sendable, CaseIterable, Identifiable {
    /// Don't judge by appearance at all: only the tiers that do not need a
    /// threshold. A burst is Apple's own grouping and an identical match is a
    /// metadata signature the feature prints then confirmed, so what is left is
    /// everything Scolo can be certain of and nothing it had to weigh up.
    case identicalOnly
    case veryStrict
    case strict
    case standard
    case loose
    case veryLoose

    public var id: String { rawValue }

    /// Nil where appearance is not consulted, which is not the same as zero: a
    /// threshold of zero would still group two images whose prints match exactly.
    public var threshold: Float? {
        switch self {
        case .identicalOnly: nil
        case .veryStrict:    0.15
        case .strict:        0.25
        case .standard:      0.35
        case .loose:         0.45
        case .veryLoose:     0.55
        }
    }

    /// Writes this setting into a grouper's options.
    ///
    /// A method rather than a threshold the caller reads, so that "no threshold"
    /// cannot be turned into a number by whoever happens to be holding it.
    public func apply(to options: inout DuplicateGrouper.Options) {
        if let threshold {
            options.comparesAppearance = true
            options.similarityThreshold = threshold
        } else {
            options.comparesAppearance = false
        }
    }

    /// Named for what it does to the results, not for how strict it sounds: "fewer
    /// groups" and "more groups" are the things the user is about to see.
    public var title: String {
        switch self {
        case .identicalOnly: "Identical only"
        case .veryStrict: "Nearly identical"
        case .strict:     "Very alike"
        case .standard:   "Alike"
        case .loose:      "Loosely alike"
        case .veryLoose:  "Vaguely alike"
        }
    }

    public var detail: String {
        switch self {
        case .identicalOnly:
            "Only bursts and identical copies. Nothing here was decided by how alike "
                + "two photographs look, so nothing here is a judgement call."
        case .veryStrict:
            "Fewest groups. The same shot re-saved or re-imported, little else."
        case .strict:
            "Frames from one burst of shooting, and near-misses of the same subject."
        case .standard:
            "The default. Photographs of the same thing, moments apart."
        case .loose:
            "More groups, and more of them worth arguing with."
        case .veryLoose:
            "Anything with a family resemblance. Expect unrelated screenshots together."
        }
    }

    /// Shown beside the title so the scale on the group badges is legible. Empty
    /// where there is no threshold, rather than a zero that would read as one.
    public var thresholdLabel: String {
        threshold.map { String(format: "%.2f", $0) } ?? ""
    }

    public static let `default` = PhotoSimilarity.standard

    /// The loosest setting there is, and so the distance out to which a sweep has
    /// to compare. Beyond this nothing can be asked, which is why
    /// `PhotoNeighbourGraph` is built exactly this far and refuses further.
    public static let ceiling: Float = allCases.compactMap(\.threshold).max() ?? 0.55
}
