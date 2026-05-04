import Foundation
import Lattice

/// One group the local user has joined — i.e. holds the shared secret
/// for. Lives in `prefs.lattice` (not in any per-room file) because the
/// group secret is **local** to this user's device; it never enters a
/// room's synced state. The room only ever sees `Session.groupHashHex`,
/// which is `base64url(sha256(secret))` — sufficient to bucket the
/// directory listing without exposing the secret to the Worker or to
/// peers in unrelated groups.
///
/// **Threat model**: the secret is stored plaintext in `secretBase64`.
/// A leaked group secret lets an attacker compute the hash and
/// **see** which Canary rooms exist; it does **not** let them join
/// any room (each room has its own `joinCode` bearer, independent of
/// the group secret). Keychain migration is a future option — see
/// the plan's "Decisions Deferred" section.
///
/// `hashHex` is `@Unique` so pasting the same invite twice is
/// idempotent — duplicates resolve to the existing row instead of
/// stacking. Two groups with the same `name` but different secrets
/// (e.g. before-and-after a key rotation) coexist; the UI
/// disambiguates them with `addedAt` or a hash prefix.
@Model
public final class LocalGroup {
    /// `base64url(sha256(secret))`. Same value the directory Worker
    /// uses as a bucket key for `POST /publish` and `GET /list?group=`.
    @Unique()
    public var hashHex: String = ""

    /// User-facing label ("Canary"). Local-only — never sent over the
    /// wire. Two members of the same group can call it different
    /// things; the hash is what binds them together.
    public var name: String = ""

    /// Raw group secret, base64url-encoded for storage. Used to:
    /// - Re-emit the original invite (so the user can share with
    ///   another team member).
    /// - Recompute `hashHex` if we ever need to (e.g. schema migration).
    public var secretBase64: String = ""

    public var addedAt: Date = Date()
}

extension LocalGroup {
    /// User-facing label: bare `name` when unique among `peers`,
    /// `name ·<hash6>` when another `LocalGroup` shares the name.
    /// Single source of truth for the four sites that render group
    /// labels (sidebar section header, status-bar suffix, recent-row
    /// visibility marker, `/delgroup` ambiguous-error candidates) so
    /// the disambiguation is consistent.
    public func displayLabel(among peers: some Collection<LocalGroup>) -> String {
        let collides = peers.contains {
            $0.hashHex != self.hashHex && $0.name == self.name
        }
        return collides ? "\(name) ·\(hashHex.prefix(6))" : name
    }
}
