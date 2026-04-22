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
    case `default`, acceptEdits, bypassPermissions, plan
}

@LatticeEnum
public enum HandoffStatus: String, Codable, Sendable {
    case offered, accepted, declined, completed
}

@LatticeEnum
public enum HandoffReason: String, Codable, Sendable {
    case graceful, detected
}
