import Foundation

/// Map a file path / name → language slug accepted by
/// `SyntaxHighlighter.tokenize(_:language:)`. Empty string for
/// unknown extensions — the highlighter then falls through to its
/// default tokenizer (no keyword / string colouring, just plain
/// identifiers).
public func languageSlug(forFilename name: String) -> String {
    let ext = (name as NSString).pathExtension.lowercased()
    switch ext {
    case "swift": return "swift"
    case "js", "jsx", "mjs", "cjs": return "js"
    case "ts", "tsx": return "ts"
    case "py": return "python"
    case "sh", "bash", "zsh": return "sh"
    default: return ""
    }
}
