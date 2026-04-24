import Foundation

/// Claude Code's whimsical thinking-verb list. Sourced from
/// <https://deepakness.com/raw/claude-spinner-verbs/>. Used by the
/// room's "thinking" indicator while a `Turn` is `.streaming`.
///
/// The per-turn verb is chosen deterministically from the turn's
/// globalId so the label doesn't flicker between the picker calling
/// `verb(for:)` multiple times during the same turn's frame cycles.
public enum ClaudeSpinnerVerbs {
    public static let all: [String] = [
        "Accomplishing", "Actioning", "Actualizing", "Architecting", "Baking",
        "Beaming", "Beboppin'", "Befuddling", "Billowing", "Blanching",
        "Bloviating", "Boogieing", "Boondoggling", "Booping", "Bootstrapping",
        "Brewing", "Bunning", "Burrowing", "Calculating", "Canoodling",
        "Caramelizing", "Cascading", "Catapulting", "Cerebrating", "Channeling",
        "Channelling", "Choreographing", "Churning", "Clauding", "Coalescing",
        "Cogitating", "Combobulating", "Composing", "Computing", "Concocting",
        "Considering", "Contemplating", "Cooking", "Crafting", "Creating",
        "Crunching", "Crystallizing", "Cultivating", "Deciphering",
        "Deliberating", "Determining", "Dilly-dallying", "Discombobulating",
        "Doing", "Doodling", "Drizzling", "Ebbing", "Effecting", "Elucidating",
        "Embellishing", "Enchanting", "Envisioning", "Evaporating", "Fermenting",
        "Fiddle-faddling", "Finagling", "Flambéing", "Flibbertigibbeting",
        "Flowing", "Flummoxing", "Fluttering", "Forging", "Forming",
        "Frolicking", "Frosting", "Gallivanting", "Galloping", "Garnishing",
        "Generating", "Gesticulating", "Germinating", "Gitifying", "Grooving",
        "Gusting", "Harmonizing", "Hashing", "Hatching", "Herding", "Honking",
        "Hullaballooing", "Hyperspacing", "Ideating", "Imagining", "Improvising",
        "Incubating", "Inferring", "Infusing", "Ionizing", "Jitterbugging",
        "Julienning", "Kneading", "Leavening", "Levitating", "Lollygagging",
        "Manifesting", "Marinating", "Meandering", "Metamorphosing", "Misting",
        "Moonwalking", "Moseying", "Mulling", "Mustering", "Musing",
        "Nebulizing", "Nesting", "Newspapering", "Noodling", "Nucleating",
        "Orbiting", "Orchestrating", "Osmosing", "Perambulating", "Percolating",
        "Perusing", "Philosophising", "Photosynthesizing", "Pollinating",
        "Pondering", "Pontificating", "Pouncing", "Precipitating",
        "Prestidigitating", "Processing", "Proofing", "Propagating", "Puttering",
        "Puzzling", "Quantumizing", "Razzle-dazzling", "Razzmatazzing",
        "Recombobulating", "Reticulating", "Roosting", "Ruminating", "Sautéing",
        "Scampering", "Schlepping", "Scurrying", "Seasoning", "Shenaniganing",
        "Shimmying", "Simmering", "Skedaddling", "Sketching", "Slithering",
        "Smooshing", "Sock-hopping", "Spelunking", "Spinning", "Sprouting",
        "Stewing", "Sublimating", "Swirling", "Swooping", "Symbioting",
        "Synthesizing", "Tempering", "Thinking", "Thundering", "Tinkering",
        "Tomfoolering", "Topsy-turvying", "Transfiguring", "Transmuting",
        "Twisting", "Undulating", "Unfurling", "Unravelling", "Vibing",
        "Waddling", "Wandering", "Warping", "Whatchamacalliting",
        "Whirlpooling", "Whirring", "Whisking", "Wibbling", "Working",
        "Wrangling", "Zesting", "Zigzagging",
    ]

    /// Deterministic verb pick keyed on a stable id (e.g. Turn
    /// globalId). Same id → same verb, so the label stays consistent
    /// while the asterisk animates.
    public static func verb(for id: UUID?) -> String {
        guard let id else { return "Thinking" }
        // Fold the UUID bytes into an index — `UUID.hashValue` is
        // seeded per-run and would give a different verb on each
        // launch even for the same row, so sum the bytes instead.
        let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
        let sum = bytes.reduce(0) { $0 &+ Int($1) }
        return all[abs(sum) % all.count]
    }
}
