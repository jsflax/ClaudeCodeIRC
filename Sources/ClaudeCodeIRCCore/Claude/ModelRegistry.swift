import Foundation

/// Static map from Anthropic model id (as it appears in the
/// `assistant.message.model` field of a Claude Code transcript jsonl) to
/// a friendly display name and the model's maximum input-token context
/// window.
///
/// Used by `StatusLineDriver` to populate the `model` and
/// `context_window` fields of the JSON blob piped to the user's
/// statusline command. Hardcoded rather than fetched from
/// `https://api.anthropic.com/v1/models` because:
/// - Zero-config: no API key required, works offline.
/// - The cadence at which Anthropic ships new models is roughly the
///   same cadence at which we ship new ccirc releases, so updating
///   the table when needed is part of the normal release rhythm.
/// - A `ModelRegistryFreshnessTests` opt-in CI test (skipped without
///   `ANTHROPIC_API_KEY`) does hit the Models API and asserts every
///   `claude-*` id the API returns is present in `known` — so we
///   notice any drift the next time CI runs with the key set.
///
/// Add new entries here when Anthropic publishes new models. The
/// freshness test will fail on CI with the key set if `known` is
/// missing an id the API now returns.
public enum ModelRegistry {

    /// `id → (displayName, contextWindow)` for every model id we
    /// currently recognise. Display names mirror Claude Code's own
    /// labels; context window is the published `max_input_tokens`.
    ///
    /// The 1M-context Opus variant ships as a separate model id;
    /// add it here when its concrete id becomes known (the API's
    /// Models endpoint is the source of truth — see freshness test).
    public static let known: [String: (displayName: String, contextWindow: Int)] = [
        "claude-opus-4-7":            ("Opus 4.7",    200_000),
        "claude-opus-4-7[1m]":        ("Opus 4.7 (1M context)", 1_000_000),
        // 4.6 family — still surfaces in older transcripts and is the
        // model id baked into "Fast mode" sessions until they roll
        // forward. Without these entries the statusline displays the
        // raw id (e.g. "claude-opus-4-6[1m]") instead of a readable
        // label.
        "claude-opus-4-6":            ("Opus 4.6",    200_000),
        "claude-opus-4-6[1m]":        ("Opus 4.6 (1M context)", 1_000_000),
        "claude-sonnet-4-6":          ("Sonnet 4.6",  200_000),
        "claude-sonnet-4-6[1m]":      ("Sonnet 4.6 (1M context)", 1_000_000),
        // Older Opus 4.5 dated id occasionally shows up in long-lived
        // resumed sessions — keep the friendly label for it too.
        "claude-opus-4-5-20251101":   ("Opus 4.5",    200_000),
        "claude-haiku-4-5":           ("Haiku 4.5",   200_000),
        "claude-haiku-4-5-20251001":  ("Haiku 4.5",   200_000),
    ]

    /// Look up a model. Unknown ids fall back to forwarding the raw
    /// model id as the display name and assuming a 200_000 token
    /// window — better an honest "claude-foo-x [...] N%" than a
    /// generic "Claude" + zero usage.
    public static func info(for modelId: String) -> (displayName: String, contextWindow: Int) {
        known[modelId] ?? (modelId, 200_000)
    }
}
