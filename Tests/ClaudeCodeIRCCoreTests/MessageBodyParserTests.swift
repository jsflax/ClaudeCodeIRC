import Foundation
import Testing
import ClaudeCodeIRCCore

@Suite struct MessageBodyParserTests {

    // MARK: - Plain text

    @Test func plainTextIsOneSegment() {
        #expect(MessageBodyParser.segments("hello world")
                == [.text("hello world")])
    }

    @Test func emptyStringIsEmptySegments() {
        #expect(MessageBodyParser.segments("").isEmpty)
    }

    // MARK: - Fenced code blocks

    @Test func fencedCodeExtractsLangAndBody() {
        let input = """
            before
            ```swift
            let x = 5
            ```
            after
            """
        let got = MessageBodyParser.segments(input)
        #expect(got.count == 3)
        #expect(got[0] == .text("before\n"))
        #expect(got[1] == .code(lang: "swift", filename: nil, body: "let x = 5"))
        #expect(got[2] == .text("\nafter"))
    }

    @Test func fencedCodeCapturesFilename() {
        let input = """
            ```ts auth/backup_codes.ts
            export function f() {}
            ```
            """
        guard let seg = MessageBodyParser.segments(input).first,
              case .code(let lang, let filename, let body) = seg else {
            Issue.record("expected a .code segment")
            return
        }
        #expect(lang == "ts")
        #expect(filename == "auth/backup_codes.ts")
        #expect(body == "export function f() {}")
    }

    @Test func fencedDiffBecomesDiffSegment() {
        // ```diff blocks route through the diff case so renderers
        // know to do per-line +/- coloring.
        let input = """
            ```diff some/file.swift
            -old
            +new
            ```
            """
        guard let seg = MessageBodyParser.segments(input).first,
              case .diff(let file, let patch) = seg else {
            Issue.record("expected a .diff segment")
            return
        }
        #expect(file == "some/file.swift")
        #expect(patch == "-old\n+new")
    }

    @Test func unmatchedFenceStaysText() {
        // Missing closing fence — the regex doesn't match, so the
        // input falls through as a single text segment. Better than
        // eating everything after the opening fence.
        let input = """
            ```swift
            let x = 5
            (no closing fence)
            """
        #expect(MessageBodyParser.segments(input) == [.text(input)])
    }

    // MARK: - Unified diffs inside plain text

    @Test func diffGitHeaderStartsDiffBlock() {
        let input = """
            here's a patch:
            diff --git a/foo.swift b/foo.swift
            index 123..456 100644
            --- a/foo.swift
            +++ b/foo.swift
            @@ -1,3 +1,3 @@
            -old
            +new
             context

            and some trailing prose
            """
        let got = MessageBodyParser.segments(input)
        #expect(got.count == 3)
        #expect(got[0] == .text("here's a patch:"))
        guard case .diff(let file, _) = got[1] else {
            Issue.record("expected middle segment to be diff")
            return
        }
        #expect(file == "foo.swift")
        if case .text(let s) = got[2] {
            #expect(s.contains("trailing prose"))
        } else {
            Issue.record("expected tail text segment")
        }
    }

    @Test func multipleFencesInterleaveWithText() {
        let input = """
            first
            ```js
            a
            ```
            middle
            ```py
            b
            ```
            last
            """
        let got = MessageBodyParser.segments(input)
        #expect(got.count == 5)
        #expect(got[1] == .code(lang: "js", filename: nil, body: "a"))
        #expect(got[3] == .code(lang: "py", filename: nil, body: "b"))
    }
}
