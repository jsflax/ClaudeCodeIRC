import Lattice

@LatticeEnum
public enum TurnStatus: String, Codable, Sendable {
    case pending, streaming, done, errored
}

@LatticeEnum
public enum MessageKind: String, Codable, Sendable {
    case user, assistant, system
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

@LatticeEnum
public enum HandoffStatus: String, Codable, Sendable {
    case offered, accepted, declined, completed
}

@LatticeEnum
public enum HandoffReason: String, Codable, Sendable {
    case graceful, detected
}
