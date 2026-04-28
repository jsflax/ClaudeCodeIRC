import Lattice
import NCursesUI

@LatticeEnum
public enum TurnStatus: String, Codable, Sendable {
    case pending, streaming, done, errored
}

@LatticeEnum
public enum MessageKind: String, Codable, Sendable {
    case user, assistant, system, action
}

/// Built-in palette selection. Persisted on `AppPreferences.paletteId`.
@LatticeEnum
public enum PaletteId: String, Codable, Sendable, CaseIterable {
    case phosphor, amber, modern, claude

    /// Bridge to the NCursesUI `Palette` theme.
    public var palette: Palette {
        switch self {
        case .phosphor: return .phosphor
        case .amber:    return .amber
        case .modern:   return .modern
        case .claude:   return .claude
        }
    }
}

@LatticeEnum
public enum ToolStatus: String, Codable, Sendable {
    case pending, running, ok, errored, denied
}

@LatticeEnum
public enum ApprovalStatus: String, Codable, Sendable {
    case pending, approved, denied
}

@LatticeEnum
public enum AskStatus: String, Codable, Sendable {
    case pending, answered, cancelled
}

@LatticeEnum
public enum PermissionMode: String, Codable, Sendable {
    case `default`, acceptEdits, plan, auto, bypassPermissions

    /// Shift-Tab cycles forward through the same four visible modes
    /// claude code's own TUI exposes. `bypassPermissions` is
    /// deliberately excluded from the cycle — it disables every
    /// safety surface and shouldn't be reachable via a random
    /// keypress. It can still be set explicitly by code paths that
    /// opt in.
    public func next() -> PermissionMode {
        switch self {
        case .default:            return .acceptEdits
        case .acceptEdits:        return .plan
        case .plan:               return .auto
        case .auto:               return .default
        case .bypassPermissions:  return .default
        }
    }

    /// Short label for the status bar.
    public var label: String {
        switch self {
        case .default:            return "default"
        case .acceptEdits:        return "accept-edits"
        case .plan:               return "plan"
        case .auto:               return "auto"
        case .bypassPermissions:  return "bypass"
        }
    }
}

/// How a hosted room is announced to the world.
///
/// - `private` — LAN-only via Bonjour, plus invite-only over the internet
///   when the host has a public tunnel URL. Not listed in the directory.
/// - `public` — listed in the directory under the well-known "public"
///   bucket. Anyone can browse; entry still requires the join code.
/// - `group` — listed in the directory under an opaque `groupHashHex`
///   bucket (= base64url(sha256(groupSecret))). Only members holding the
///   group secret can compute the same hash and see the listing. Entry
///   still requires the per-room join code (independent of the group
///   secret). Pair with `Session.groupHashHex` on the same row.
@LatticeEnum
public enum SessionVisibility: String, Codable, Sendable {
    case `private`, `public`, group
}

