import CoreGraphics
@testable import Dazzle
@testable import DazzleEngine
import Foundation
import Testing

@Suite("Equations")
struct EquationTests {
    private static let math = "http://schemas.openxmlformats.org/officeDocument/2006/math"

    /// A math run of 24 point text.
    private func run(_ text: String, properties: String = "", color: String = "") -> String {
        "<m:r>\(properties)<a:rPr lang=\"en-US\" sz=\"2400\" i=\"1\">\(color)<a:latin typeface=\"Cambria Math\"/></a:rPr><m:t>\(text)</m:t></m:r>"
    }

    private func shapes(_ xml: String) throws -> [SlideShape] {
        let root = try XMLLite.parse(Data("""
            <p:spTree xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" \
            xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">\(xml)</p:spTree>
            """.utf8))
        return ShapeParser(partPath: "ppt/slides/slide1.xml", relationships: [], namespaces: OOXML.namespaces,
                           parts: [:], capturesSource: true).shapes(in: root)
    }

    /// A text box holding `math` as PowerPoint writes an equation: the Office
    /// Math for readers that know it, and for the rest a box filled green
    /// where PowerPoint would put a picture. 400 points wide, 150 tall, 100 in from the corner.
    private func equationShape(_ math: String, paragraph: Bool = true, before: String = "") throws -> SlideShape {
        let nonVisual = "<p:nvSpPr><p:cNvPr id=\"4\" name=\"Equation\"/><p:cNvSpPr txBox=\"1\"/><p:nvPr/></p:nvSpPr>"
        let frame = "<a:xfrm><a:off x=\"1270000\" y=\"1270000\"/><a:ext cx=\"5080000\" cy=\"1905000\"/></a:xfrm><a:prstGeom prst=\"rect\"/>"
        let held = paragraph ? "<m:oMathPara xmlns:m=\"\(Self.math)\"><m:oMath>\(math)</m:oMath></m:oMathPara>"
            : "<m:oMath xmlns:m=\"\(Self.math)\">\(math)</m:oMath>"
        return try #require(shapes("""
            <mc:AlternateContent xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" \
            xmlns:a14="http://schemas.microsoft.com/office/drawing/2010/main"><mc:Choice Requires="a14">
            <p:sp>\(nonVisual)<p:spPr>\(frame)<a:noFill/></p:spPr>
            <p:txBody><a:bodyPr lIns="0" tIns="0" rIns="0" bIns="0" anchor="ctr"/><a:lstStyle/><a:p>\(before)<a14:m>\(held)</a14:m></a:p></p:txBody></p:sp>
            </mc:Choice><mc:Fallback><p:sp>\(nonVisual)<p:spPr>\(frame)<a:solidFill><a:srgbClr val="00FF00"/></a:solidFill></p:spPr>
            <p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:rPr lang="en-US"><a:noFill/></a:rPr><a:t> </a:t></a:r></a:p></p:txBody></p:sp>
            </mc:Fallback></mc:AlternateContent>
            """).first)
    }

    private func equation(_ math: String, paragraph: Bool = true) throws -> MathEquation {
        let shape = try equationShape(math, paragraph: paragraph)
        let runs = try #require(shape.text?.paragraphs.first?.runs)
        for run in runs {
            if case .equation(let equation) = run.kind { return equation }
        }
        throw CocoaError(.coderValueNotFound)
    }

    /// A fraction of `numerator` over `denominator`.
    private func fraction(_ numerator: String, _ denominator: String, type: String = "") -> String {
        "<m:f><m:fPr>\(type)</m:fPr><m:num>\(numerator)</m:num><m:den>\(denominator)</m:den></m:f>"
    }

    private func laidOut(_ math: String, paragraph: Bool = true) throws -> MathBox {
        MathLayout(fontSize: 24, color: CGColor(gray: 0, alpha: 1)).box(for: try equation(math, paragraph: paragraph))
    }

    /// Where the slide's drawing leaves ink, a pixel to the point: every pixel's colour and opacity.
    private struct Ink {
        var width: Int
        var height: Int
        var pixels: Data

        /// How many pixels in `rect` pass `test`, given red, green, blue and alpha.
        func count(in rect: CGRect, where test: (UInt8, UInt8, UInt8, UInt8) -> Bool = { _, _, _, alpha in alpha > 128 }) -> Int {
            var count = 0
            for y in max(Int(rect.minY), 0)..<min(Int(rect.maxY), height) {
                for x in max(Int(rect.minX), 0)..<min(Int(rect.maxX), width) {
                    let offset = (y * width + x) * 4
                    if test(pixels[offset], pixels[offset + 1], pixels[offset + 2], pixels[offset + 3]) { count += 1 }
                }
            }
            return count
        }

        /// The smallest rectangle holding every inked pixel in `rect`.
        func bounds(in rect: CGRect) -> CGRect {
            var bounds = CGRect.null
            for y in max(Int(rect.minY), 0)..<min(Int(rect.maxY), height) {
                for x in max(Int(rect.minX), 0)..<min(Int(rect.maxX), width) where pixels[(y * width + x) * 4 + 3] > 128 {
                    bounds = bounds.union(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
            return bounds
        }
    }

    private func ink(_ shape: SlideShape) throws -> Ink {
        var presentation = Presentation.blank
        presentation.slides[0].shapes = [shape]
        let size = presentation.slideSize.points
        let width = Int(size.width), height = Int(size.height)
        let canvas = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                            space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        canvas.translateBy(x: 0, y: CGFloat(height))
        canvas.scaleBy(x: 1, y: -1)
        SlideRenderer(presentation: presentation, slide: presentation.slides[0], options: .init(drawsBackground: false))
            .draw(in: canvas, size: CGSize(width: width, height: height))
        let pixels = try #require(canvas.makeImage()?.dataProvider?.data as Data?)
        return Ink(width: width, height: height, pixels: pixels)
    }

    private let box = CGRect(x: 100, y: 100, width: 400, height: 150)

    // MARK: - Reading

    @Test("The equation is read rather than its fallback picture, as one run of the paragraph, and the shape is kept as it was")
    func readsChoice() throws {
        let shape = try equationShape(run("x=") + fraction(run("a"), run("b")))
        #expect(shape.fill == Fill.none)
        #expect(shape.isLocked)
        #expect(!shape.isEditable)
        #expect(shape.text?.hasEquation == true)
        let paragraph = try #require(shape.text?.paragraphs.first)
        #expect(paragraph.runs.count == 1)
        #expect(paragraph.plainText == "x=a/b")
        #expect(paragraph.runs[0].properties.size == 2_400)
        // A math paragraph is centred unless it says otherwise.
        #expect(paragraph.properties.alignment == .center)
        guard case .equation(let equation) = paragraph.runs[0].kind else {
            Issue.record("not an equation")
            return
        }
        #expect(equation.isDisplay)
        #expect(equation.content.count == 2)
        // The whole is written back just as it was read.
        #expect(shape.source?.contains("<mc:Fallback>") == true)
        #expect(shape.source?.contains("<m:f>") == true)
    }

    @Test("An equation within a line of text sits among its runs, set as inline math")
    func readsInline() throws {
        let shape = try equationShape(run("x"), paragraph: false, before: "<a:r><a:rPr lang=\"en-US\" sz=\"2400\"/><a:t>Let </a:t></a:r>")
        let paragraph = try #require(shape.text?.paragraphs.first)
        #expect(paragraph.runs.count == 2)
        #expect(paragraph.plainText == "Let x")
        #expect(paragraph.properties.alignment == nil)
        guard case .equation(let equation) = paragraph.runs[1].kind else {
            Issue.record("not an equation")
            return
        }
        #expect(!equation.isDisplay)
    }

    @Test("A shape offered two ways with no equation in it is still read from its fallback")
    func keepsFallbackForOthers() throws {
        let shape = try #require(shapes("""
            <mc:AlternateContent xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006"><mc:Choice Requires="p14">
            <p:sp><p:nvSpPr><p:cNvPr id="4" name="New"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr/></p:sp></mc:Choice>
            <mc:Fallback><p:sp><p:nvSpPr><p:cNvPr id="4" name="Old"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr/></p:sp></mc:Fallback>
            </mc:AlternateContent>
            """).first)
        #expect(shape.name == "Old")
        #expect(shape.isLocked)
    }

    @Test("Fractions, scripts, radicals, operators, delimiters and matrices are read with their properties and defaults")
    func readsStructures() throws {
        func only(_ math: String) throws -> MathNode { try #require(try equation(math).content.first) }
        func text(_ nodes: [MathNode]?) -> String? { nodes.map { MathNode.linearText($0) } }

        guard case .fraction(.bar, let numerator, let denominator) = try only(fraction(run("a"), run("b"))) else {
            Issue.record("not a fraction")
            return
        }
        #expect(text(numerator) == "a" && text(denominator) == "b")
        if case .fraction(let kind, _, _) = try only(fraction(run("n"), run("k"), type: "<m:type m:val=\"noBar\"/>")) {
            #expect(kind == .noBar)
        } else {
            Issue.record("not a fraction")
        }

        let both = try only("<m:sSubSup><m:e>\(run("x"))</m:e><m:sub>\(run("i"))</m:sub><m:sup>\(run("2"))</m:sup></m:sSubSup>")
        #expect(both == .scripts(base: try equation(run("x")).content, sub: try equation(run("i")).content,
                                 sup: try equation(run("2")).content, isBefore: false))
        if case .scripts(_, let sub, let sup, let isBefore) = try only(
            "<m:sPre><m:sub>\(run("6"))</m:sub><m:sup>\(run("14"))</m:sup><m:e>\(run("C"))</m:e></m:sPre>"
        ) {
            #expect(text(sub) == "6" && text(sup) == "14" && isBefore)
        } else {
            Issue.record("not scripts")
        }

        // A root whose degree is hidden is a square root.
        let square = try only("<m:rad><m:radPr><m:degHide m:val=\"1\"/></m:radPr><m:deg/><m:e>\(run("x"))</m:e></m:rad>")
        let cube = try only("<m:rad><m:deg>\(run("3"))</m:deg><m:e>\(run("x"))</m:e></m:rad>")
        if case .radical(let degree, let radicand) = square { #expect(degree == nil && text(radicand) == "x") } else { Issue.record("not a root") }
        if case .radical(let degree, _) = cube { #expect(text(degree) == "3") } else { Issue.record("not a root") }

        // An operator is an integral unless told otherwise, with its limits at its side; a sum's go above and below.
        let integral = try only("<m:nary><m:sub>\(run("0"))</m:sub><m:sup>\(run("1"))</m:sup><m:e>\(run("x"))</m:e></m:nary>")
        if case .nary(let symbol, let limits, let sub, let sup, let body) = integral {
            #expect(symbol == "∫" && limits == .subSup && text(sub) == "0" && text(sup) == "1" && text(body) == "x")
        } else {
            Issue.record("not an operator")
        }
        let sum = try only("""
            <m:nary><m:naryPr><m:chr m:val="∑"/><m:supHide m:val="1"/></m:naryPr><m:sub>\(run("i"))</m:sub><m:sup/><m:e>\(run("x"))</m:e></m:nary>
            """)
        if case .nary(let symbol, let limits, let sub, let sup, _) = sum {
            #expect(symbol == "∑" && limits == .underOver && text(sub) == "i" && sup == nil)
        } else {
            Issue.record("not an operator")
        }

        // Delimiters are round brackets unless told otherwise, their parts set apart by bars.
        if case .delimited(let open, let close, let separator, let parts) = try only("<m:d><m:e>\(run("a"))</m:e><m:e>\(run("b"))</m:e></m:d>") {
            #expect(open == "(" && close == ")" && separator == "|" && parts.count == 2)
        } else {
            Issue.record("not delimited")
        }
        let braced = try only("<m:d><m:dPr><m:begChr m:val=\"{\"/><m:endChr m:val=\"\"/></m:dPr><m:e>\(run("a"))</m:e></m:d>")
        if case .delimited(let open, let close, _, _) = braced { #expect(open == "{" && close.isEmpty) } else { Issue.record("not delimited") }

        let matrix = try only("""
            <m:m><m:mPr><m:mcs><m:mc><m:mcPr><m:count m:val="2"/><m:mcJc m:val="left"/></m:mcPr></m:mc></m:mcs></m:mPr>
            <m:mr><m:e>\(run("a"))</m:e><m:e>\(run("b"))</m:e></m:mr><m:mr><m:e>\(run("c"))</m:e><m:e>\(run("d"))</m:e></m:mr></m:m>
            """)
        if case .matrix(let rows, let alignments, let isEquationArray) = matrix {
            #expect(rows.map { $0.map { MathNode.linearText($0) } } == [["a", "b"], ["c", "d"]])
            #expect(alignments == [.left, .left] && !isEquationArray)
        } else {
            Issue.record("not a matrix")
        }

        // An equation array's rows are cut where an ampersand aligns them.
        let array = try only("<m:eqArr><m:e>\(run("x&amp;=1"))</m:e><m:e>\(run("y+z&amp;=2"))</m:e></m:eqArr>")
        if case .matrix(let rows, let alignments, let isEquationArray) = array {
            #expect(rows.map { $0.map { MathNode.linearText($0) } } == [["x", "=1"], ["y+z", "=2"]])
            #expect(alignments == [.right, .left] && isEquationArray)
        } else {
            Issue.record("not an array")
        }
    }

    @Test("A run's letters are italic unless it says otherwise, and ordinary text is left as it is")
    func readsRuns() throws {
        func first(_ math: String) throws -> MathRun {
            guard case .run(let run) = try #require(try equation(math).content.first) else { throw CocoaError(.coderValueNotFound) }
            return run
        }
        #expect(try first(run("x")).variant == .italic)
        #expect(try first(run("sin", properties: "<m:rPr><m:sty m:val=\"p\"/></m:rPr>")).variant == .plain)
        #expect(try first(run("v", properties: "<m:rPr><m:sty m:val=\"bi\"/></m:rPr>")).variant == .boldItalic)
        let normal = try first(run("if x", properties: "<m:rPr><m:nor/></m:rPr>"))
        #expect(normal.isNormalText && normal.displayText == "if x")
        let red = try first(run("x", color: "<a:solidFill><a:srgbClr val=\"FF0000\"/></a:solidFill>"))
        #expect(red.properties.color != nil)
    }

    @Test("Letters are drawn from the math alphabet their run asks for")
    func alphabets() {
        #expect(MathAlphabet.styled("x", variant: .italic) == "𝑥")
        #expect(MathAlphabet.styled("AZaz", variant: .italic) == "𝐴𝑍𝑎𝑧")
        // The italic h is the Planck constant, which Unicode already had.
        #expect(MathAlphabet.styled("h", variant: .italic) == "ℎ")
        #expect(MathAlphabet.styled("αωΓ", variant: .italic) == "𝛼𝜔𝛤")
        #expect(MathAlphabet.styled("x1", variant: .bold) == "𝐱𝟏")
        #expect(MathAlphabet.styled("x", variant: .boldItalic) == "𝒙")
        #expect(MathAlphabet.styled("sin 2x", variant: .plain) == "sin 2x")
        // Digits and signs stay as they are, but a hyphen is a minus sign.
        #expect(MathAlphabet.styled("2-1=1", variant: .italic) == "2−1=1")
        // Letters PowerPoint already wrote from a math alphabet are left alone.
        #expect(MathAlphabet.styled("𝑥", variant: .italic) == "𝑥")
    }

    // MARK: - Layout

    @Test("A fraction stacks its parts about the middle of the line, wider than either")
    func fractionLayout() throws {
        let letter = try laidOut(run("a"))
        let stacked = try laidOut(fraction(run("a"), run("b")))
        #expect(stacked.ascent > letter.ascent + 8)
        #expect(stacked.descent > letter.descent + 8)
        #expect(stacked.width > letter.width)
        // The numerator, the bar and the denominator.
        #expect(stacked.markCount == 3)
        #expect(try laidOut(fraction(run("a"), run("b"), type: "<m:type m:val=\"noBar\"/>")).markCount == 2)
        // In a line of text a fraction's parts are set smaller than in a paragraph of its own.
        let inline = try laidOut(fraction(run("a"), run("b")), paragraph: false)
        #expect(inline.ascent + inline.descent < stacked.ascent + stacked.descent)
    }

    @Test("Scripts are set smaller, raised above and lowered below their base")
    func scriptLayout() throws {
        let base = try laidOut(run("x"))
        let raised = try laidOut("<m:sSup><m:e>\(run("x"))</m:e><m:sup>\(run("2"))</m:sup></m:sSup>")
        let lowered = try laidOut("<m:sSub><m:e>\(run("x"))</m:e><m:sub>\(run("i"))</m:sub></m:sSub>")
        #expect(raised.ascent > base.ascent + 2)
        #expect(abs(raised.descent - base.descent) < 0.01)
        #expect(lowered.descent > base.descent + 2)
        #expect(abs(lowered.ascent - base.ascent) < 0.01)
        // A script is narrower than the same thing on the line.
        let digit = try laidOut(run("2"))
        #expect(raised.width < base.width + digit.width)
        #expect(raised.width > base.width + digit.width * 0.5)
    }

    @Test("A radical's sign and line reach over what the root is taken of")
    func radicalLayout() throws {
        let inner = try laidOut(fraction(run("a"), run("b")))
        let root = try laidOut("<m:rad><m:radPr><m:degHide m:val=\"1\"/></m:radPr><m:deg/><m:e>\(fraction(run("a"), run("b")))</m:e></m:rad>")
        #expect(root.ascent > inner.ascent)
        #expect(root.descent >= inner.descent)
        #expect(root.width > inner.width + 8)
        let cube = try laidOut("<m:rad><m:deg>\(run("3"))</m:deg><m:e>\(fraction(run("a"), run("b")))</m:e></m:rad>")
        #expect(cube.markCount > root.markCount)
    }

    @Test("An operator is drawn large, its limits above and below or at its side as it says")
    func operatorLayout() throws {
        func sum(_ location: String) -> String {
            """
            <m:nary><m:naryPr><m:chr m:val="∑"/><m:limLoc m:val="\(location)"/></m:naryPr>\
            <m:sub>\(run("i=1"))</m:sub><m:sup>\(run("n"))</m:sup><m:e>\(run("i"))</m:e></m:nary>
            """
        }
        let sign = try laidOut(run("∑"))
        let stacked = try laidOut(sum("undOvr"))
        let beside = try laidOut(sum("subSup"))
        #expect(stacked.ascent + stacked.descent > (sign.ascent + sign.descent) * 1.8)
        // Limits at the side leave the operator shorter and the whole wider.
        #expect(beside.ascent + beside.descent < stacked.ascent + stacked.descent)
        #expect(beside.width > stacked.width)
    }

    @Test("Delimiters grow to hold what is between them")
    func delimiterLayout() throws {
        func delimited(_ content: String, _ open: String = "(", _ close: String = ")") -> String {
            "<m:d><m:dPr><m:begChr m:val=\"\(open)\"/><m:endChr m:val=\"\(close)\"/></m:dPr><m:e>\(content)</m:e></m:d>"
        }
        let small = try laidOut(delimited(run("x")))
        let content = try laidOut(fraction(fraction(run("a"), run("b")), run("c")))
        for (open, close) in [("(", ")"), ("[", "]"), ("{", "}"), ("|", "|"), ("⟨", "⟩"), ("⌊", "⌋")] {
            let tall = try laidOut(delimited(fraction(fraction(run("a"), run("b")), run("c")), open, close))
            #expect(tall.ascent >= content.ascent && tall.descent >= content.descent, "\(open) covers its content")
            #expect(tall.ascent + tall.descent > (small.ascent + small.descent) * 1.5, "\(open) grows")
            #expect(tall.width > content.width, "\(open) has room at each side")
        }
        // With no closing delimiter, only the opening one is drawn.
        let open = try laidOut(delimited(fraction(run("a"), run("b")), "{", ""))
        let closed = try laidOut(delimited(fraction(run("a"), run("b")), "{", "}"))
        #expect(open.width < closed.width)
    }

    @Test("A matrix sets its cells in rows and columns about the middle of the line")
    func matrixLayout() throws {
        func matrix(_ rows: [[String]]) -> String {
            "<m:m>" + rows.map { "<m:mr>" + $0.map { "<m:e>\(run($0))</m:e>" }.joined() + "</m:mr>" }.joined() + "</m:m>"
        }
        let cell = try laidOut(run("a"))
        let square = try laidOut(matrix([["a", "b"], ["c", "d"]]))
        let row = try laidOut(matrix([["a", "b"]]))
        let column = try laidOut(matrix([["b"], ["d"]]))
        #expect(square.width > cell.width * 2 + 10)
        #expect(abs(square.width - row.width) < 2)
        #expect(abs((square.ascent + square.descent) - (column.ascent + column.descent)) < 0.01)
        #expect(square.ascent + square.descent > (row.ascent + row.descent) * 1.8)
        // As far above the middle of the line as below it.
        #expect(abs((square.ascent - 6) - (square.descent + 6)) < 0.01)
        #expect(square.markCount == 4)
    }

    // MARK: - Drawing and writing

    @Test("The equation is drawn in the shape, centred, its fraction above and below the line, and the fallback is not")
    func draws() throws {
        let shape = try equationShape(run("x=") + fraction(run("a+b"), run("c")))
        let drawn = try ink(shape)
        // None of the fallback's green.
        #expect(drawn.count(in: box) { red, green, _, alpha in alpha > 128 && green > 200 && red < 80 } == 0)
        let bounds = drawn.bounds(in: box.insetBy(dx: -50, dy: -50))
        #expect(!bounds.isNull)
        #expect(bounds.width > 60 && bounds.width < 160)
        // Taller than a line of 24 point text, as a fraction is.
        #expect(bounds.height > 30 && bounds.height < 90)
        #expect(abs(bounds.midX - box.midX) < 6, "centred across")
        #expect(abs(bounds.midY - box.midY) < 12, "anchored in the middle")
        #expect(drawn.count(in: bounds) > 200)
    }

    @Test("A run of the equation is drawn in its own colour")
    func drawsColors() throws {
        let red = "<a:solidFill><a:srgbClr val=\"FF0000\"/></a:solidFill>"
        let drawn = try ink(try equationShape(run("x+") + run("y", color: red)))
        #expect(drawn.count(in: box) { red, green, _, alpha in alpha > 128 && red > 200 && green < 60 } > 10)
        #expect(drawn.count(in: box) { red, _, _, alpha in alpha > 128 && red < 60 } > 10)
    }

    @Test("Saving writes the equation and its fallback back as they were read")
    func saves() throws {
        var presentation = Presentation.blank
        presentation.slides[0].shapes = [try equationShape(run("x=") + fraction(run("a"), run("b")))]
        presentation.slides[0].isModified = true
        let reopened = try PPTXReader.presentation(from: PPTXWriter.data(from: presentation))
        let shape = try #require(reopened.slides[0].shapes.first { $0.name == "Equation" })
        #expect(shape.text?.plainText == "x=a/b")
        #expect(shape.text?.hasEquation == true)
        #expect(shape.source?.contains("<mc:Fallback>") == true)
    }

    @Test("MathML for the web names each structure")
    func mathML() throws {
        let markup = try equation(run("x=") + fraction(run("-b"), run("2a"))).mathML()
        #expect(markup.hasPrefix("<math xmlns=\"http://www.w3.org/1998/Math/MathML\" displaystyle=\"true\">"))
        #expect(markup.contains("<mi>𝑥</mi><mo stretchy=\"false\">=</mo>"))
        #expect(markup.contains("<mfrac><mrow><mo stretchy=\"false\">−</mo><mi>𝑏</mi></mrow><mrow><mn>2</mn><mi>𝑎</mi></mrow></mfrac>"))
        let root = try equation("<m:rad><m:deg>\(run("3"))</m:deg><m:e>\(run("x"))</m:e></m:rad>").mathML()
        #expect(root.contains("<mroot><mrow><mi>𝑥</mi></mrow><mrow><mn>3</mn></mrow></mroot>"))
        let upright = try equation(run("sin", properties: "<m:rPr><m:sty m:val=\"p\"/></m:rPr>"), paragraph: false).mathML()
        #expect(upright.contains("displaystyle=\"false\""))
        #expect(upright.contains("<mi mathvariant=\"normal\">sin</mi>"))
    }
}
