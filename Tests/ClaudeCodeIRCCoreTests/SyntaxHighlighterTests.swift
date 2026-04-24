import Foundation
import Testing
import ClaudeCodeIRCCore

@Suite struct SyntaxHighlighterTests {

    // MARK: - Keywords

    @Test func tsKeywordsAreMarkedKeyword() {
        let tokens = SyntaxHighlighter.tokenize("const x = 5", language: "ts")
        #expect(tokens.first?.text == "const")
        #expect(tokens.first?.kind == .keyword)
        // Ident
        #expect(tokens.contains(where: { $0.text == "x" && $0.kind == .identifier }))
        // Number
        #expect(tokens.contains(where: { $0.text == "5" && $0.kind == .number }))
    }

    @Test func swiftKeywordsIncludeStructAndFunc() {
        let tokens = SyntaxHighlighter.tokenize(
            "struct S { func f() {} }", language: "swift")
        #expect(tokens.filter { $0.kind == .keyword }
            .map(\.text)
            .sorted() == ["func", "struct"])
    }

    @Test func pythonKeywordsIncludeDef() {
        let tokens = SyntaxHighlighter.tokenize(
            "def f():\n    return 1", language: "py")
        #expect(tokens.contains(where: { $0.text == "def" && $0.kind == .keyword }))
        #expect(tokens.contains(where: { $0.text == "return" && $0.kind == .keyword }))
    }

    // MARK: - Literals

    @Test func doubleQuotedStringIsString() {
        let tokens = SyntaxHighlighter.tokenize(#"let s = "hello""#, language: "swift")
        #expect(tokens.contains(where: { $0.text == #""hello""# && $0.kind == .string }))
    }

    @Test func escapedQuotesStayInsideString() {
        let tokens = SyntaxHighlighter.tokenize(
            #""he said \"hi\"""#, language: "js")
        #expect(tokens.first?.kind == .string)
        #expect(tokens.first?.text == #""he said \"hi\"""#)
    }

    // MARK: - Comments

    @Test func doubleSlashLineComment() {
        let tokens = SyntaxHighlighter.tokenize(
            "let x = 1 // a note", language: "swift")
        #expect(tokens.last?.kind == .comment)
        #expect(tokens.last?.text == "// a note")
    }

    @Test func hashLineCommentInShell() {
        let tokens = SyntaxHighlighter.tokenize(
            "echo hi # trailing", language: "sh")
        #expect(tokens.last?.kind == .comment)
    }

    @Test func blockCommentConsumedAsOne() {
        let tokens = SyntaxHighlighter.tokenize(
            "/* multi\nline */x", language: "js")
        #expect(tokens.first?.kind == .comment)
        #expect(tokens.first?.text == "/* multi\nline */")
    }

    // MARK: - Numbers + identifiers

    @Test func integerAndFloatBothNumbers() {
        let intTokens = SyntaxHighlighter.tokenize("42", language: "ts")
        let floatTokens = SyntaxHighlighter.tokenize("3.14", language: "ts")
        #expect(intTokens.first?.kind == .number)
        #expect(floatTokens.first?.kind == .number)
        #expect(floatTokens.first?.text == "3.14")
    }

    @Test func identifierWithUnderscoresAndDigits() {
        let tokens = SyntaxHighlighter.tokenize("a_2b", language: "swift")
        #expect(tokens.first?.kind == .identifier)
        #expect(tokens.first?.text == "a_2b")
    }

    // MARK: - Diff

    @Test func diffAddLinesMarkedAdd() {
        let tokens = SyntaxHighlighter.tokenize("+new line", language: "diff")
        #expect(tokens.first?.kind == .diffAdd)
    }

    @Test func diffRemoveLinesMarkedRemove() {
        let tokens = SyntaxHighlighter.tokenize("-old line", language: "diff")
        #expect(tokens.first?.kind == .diffRemove)
    }

    @Test func hunkHeaderMarkedHunk() {
        let tokens = SyntaxHighlighter.tokenize("@@ -1,3 +1,3 @@", language: "diff")
        #expect(tokens.first?.kind == .diffHunk)
    }

    @Test func diffMetaHeadersMarkedMeta() {
        let tokens = SyntaxHighlighter.tokenize(
            "--- a/foo\n+++ b/foo", language: "diff")
        #expect(tokens.first?.kind == .diffMeta)
        #expect(tokens.contains(where: { $0.kind == .diffMeta && $0.text == "+++ b/foo" }))
    }
}
