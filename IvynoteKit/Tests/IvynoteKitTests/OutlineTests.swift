import Testing
@testable import IvynoteKit

@Suite struct OutlineTests {
    @Test func findsHeadingsWithLevelsAndLines() {
        let body = "# Title\n\ntext\n## Part one ##\n### Deep\n#nospace\n####### seven"
        #expect(Outline.headings(in: body) == [
            Heading(level: 1, text: "Title", line: 0),
            Heading(level: 2, text: "Part one", line: 3),
            Heading(level: 3, text: "Deep", line: 4),
        ])
    }

    @Test func skipsFencedCode() {
        let body = "```sh\n# not a heading\n```\n## Real\n~~~\n# also not\n~~~"
        #expect(Outline.headings(in: body).map(\.text) == ["Real"])
    }

    @Test func emptyBody() {
        #expect(Outline.headings(in: "").isEmpty)
    }

    @Test func currentIsTheSectionAtTheTop() {
        let hs = [Heading(level: 1, text: "A", line: 2), Heading(level: 2, text: "B", line: 10)]
        #expect(Outline.current(in: hs, top: 0) == nil)
        #expect(Outline.current(in: hs, top: 2) == 2)
        #expect(Outline.current(in: hs, top: 9) == 2)
        #expect(Outline.current(in: hs, top: 40) == 10)
    }
}
