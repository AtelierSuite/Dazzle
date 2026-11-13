#!/usr/bin/env python3
"""Generates Engine/DazzleEngine/Rendering/PresetShapeDefinitions.swift from
ECMA-376's presetShapeDefinitions.xml (Part 1, in OfficeOpenXML-DrawingMLGeometries.zip),
and PresetTextWarpDefinitions.swift from presetTextWarpDefinitions.xml beside it.

The same files ship in LibreOffice's sources:
https://raw.githubusercontent.com/LibreOffice/core/master/oox/source/drawingml/customshapes/presetShapeDefinitions.xml
https://raw.githubusercontent.com/LibreOffice/core/master/oox/source/export/presetTextWarpDefinitions.xml

Usage: Engine/Scripts/generate-preset-shapes.py path/to/presetShapeDefinitions.xml
       Engine/Scripts/generate-preset-shapes.py --text-warps path/to/presetTextWarpDefinitions.xml

Text warps are encoded as shapes are; their paths are the lines text is laid
along, and an adjust value may default to one of the angle constants.

Each preset becomes one string of `;`-separated statements, which
PresetShapeDefinition parses when a shape first needs it:

    a NAME VALUE              an adjust value and its default
    g NAME OP ARG...          a guide: OP is the formula's operator, ARGs
                              are numbers or the names of earlier values
    t L T R B                 the text rectangle
    c ANG X Y                 a connection site: where a connector meets the
                              shape, and the angle it leaves at
    p W H FILL STROKE         a path: its own coordinate space (0 for the
                              shape's), FILL n(orm), x (none), d(arken),
                              D (darkenLess), l(ighten) or L (lightenLess),
                              and STROKE 1 or 0
    M x y | L x y | A wR hR stAng swAng | Q x1 y1 x2 y2 | C x1 y1 x2 y2 x3 y3 | Z
"""

import sys
import xml.etree.ElementTree as ET

NS = "{http://schemas.openxmlformats.org/drawingml/2006/main}"
OUTPUT = "Engine/DazzleEngine/Rendering/PresetShapeDefinitions.swift"
TEXT_WARP_OUTPUT = "Engine/DazzleEngine/Rendering/PresetTextWarpDefinitions.swift"

# The names every formula can use, as PresetShapeDefinition defines them.
BUILT_INS = {
    "3cd4", "3cd8", "5cd8", "7cd8", "b", "cd2", "cd4", "cd8", "h", "hc", "hd2", "hd3", "hd4", "hd5", "hd6", "hd10",
    "hd8", "l", "ls", "r", "ss", "ssd2", "ssd4", "ssd6", "ssd8", "ssd16", "ssd32", "t", "vc", "w", "wd2",
    "wd3", "wd4", "wd5", "wd6", "wd8", "wd10", "wd12", "wd32",
}
ARITY = {
    "*/": 3, "+-": 3, "+/": 3, "?:": 3, "abs": 1, "at2": 2, "cat2": 3, "cos": 2, "max": 2, "min": 2,
    "mod": 3, "pin": 3, "sat2": 3, "sin": 2, "sqrt": 1, "tan": 2, "val": 1,
}
# The constants an adjust value may default to (text warps' `val cd2`).
CONSTANTS = {"cd2": "10800000", "cd4": "5400000", "cd8": "2700000", "3cd4": "16200000"}
FILLS = {"norm": "n", "none": "x", "darken": "d", "darkenLess": "D", "lighten": "l", "lightenLess": "L"}


def is_number(token):
    try:
        float(token)
        return True
    except ValueError:
        return False


def encode(shape):
    known = set(BUILT_INS)
    statements = []

    def operand(token):
        if not is_number(token) and token not in known:
            raise ValueError(f"{shape.tag}: unknown name {token}")
        return token

    def name(token):
        if " " in token or ";" in token or not token:
            raise ValueError(f"{shape.tag}: bad name {token!r}")
        return token

    av = shape.find(NS + "avLst")
    for gd in av if av is not None else []:
        op, *args = gd.get("fmla").split()
        args = [CONSTANTS.get(a, a) for a in args]
        if op != "val" or len(args) != 1 or not is_number(args[0]):
            raise ValueError(f"{shape.tag}: adjust {gd.get('name')} is not a value")
        statements.append(f"a {name(gd.get('name'))} {args[0]}")
        known.add(gd.get("name"))
    gds = shape.find(NS + "gdLst")
    for gd in gds if gds is not None else []:
        op, *args = gd.get("fmla").split()
        # The circular arrows' `+- xH 0 dxB 0` has one argument too many,
        # which readers ignore.
        if op not in ARITY or len(args) < ARITY[op]:
            raise ValueError(f"{shape.tag}: formula {gd.get('fmla')}")
        args = args[:ARITY[op]]
        statements.append(" ".join(["g", name(gd.get("name")), op] + [operand(a) for a in args]))
        known.add(gd.get("name"))
    rect = shape.find(NS + "rect")
    if rect is not None:
        statements.append(" ".join(["t"] + [operand(rect.get(k)) for k in ("l", "t", "r", "b")]))
    sites = shape.find(NS + "cxnLst")
    for site in sites if sites is not None else []:
        position = site.find(NS + "pos")
        # A third of a turn is a constant no formula uses, so it has no slot.
        angle = "7200000" if site.get("ang") == "cd3" else operand(site.get("ang"))
        statements.append(" ".join(["c", angle, operand(position.get("x")), operand(position.get("y"))]))
    paths = shape.find(NS + "pathLst")
    for path in paths if paths is not None else []:
        stroke = "0" if path.get("stroke") in ("false", "0") else "1"
        statements.append(f"p {path.get('w', '0')} {path.get('h', '0')} {FILLS[path.get('fill', 'norm')]} {stroke}")
        for command in path:
            tag = command.tag.replace(NS, "")
            points = [operand(p.get(k)) for p in command.findall(NS + "pt") for k in ("x", "y")]
            if tag == "moveTo":
                statements.append("M " + " ".join(points))
            elif tag == "lnTo":
                statements.append("L " + " ".join(points))
            elif tag == "quadBezTo":
                statements.append("Q " + " ".join(points))
            elif tag == "cubicBezTo":
                statements.append("C " + " ".join(points))
            elif tag == "arcTo":
                statements.append(" ".join(["A"] + [operand(command.get(k)) for k in ("wR", "hR", "stAng", "swAng")]))
            elif tag == "close":
                statements.append("Z")
            else:
                raise ValueError(f"{shape.tag}: unknown command {tag}")
    return ";".join(statements)


def main():
    text_warps = len(sys.argv) == 3 and sys.argv[1] == "--text-warps"
    if len(sys.argv) != 2 and not text_warps:
        sys.exit(__doc__)
    root = ET.parse(sys.argv[-1]).getroot()
    if text_warps:
        lines = [
            "// Generated by Engine/Scripts/generate-preset-shapes.py from ECMA-376's",
            "// presetTextWarpDefinitions.xml. Do not edit; run the script again instead.",
            "",
            "extension PresetShapeDefinition {",
            "    /// Each text warp's adjust values, guides and the paths text is laid",
            "    /// along, as the generator encodes them.",
            "    static let encodedTextWarps: [String: String] = [",
        ]
    else:
        lines = [
            "// Generated by Engine/Scripts/generate-preset-shapes.py from ECMA-376's",
            "// presetShapeDefinitions.xml. Do not edit; run the script again instead.",
            "",
            "extension PresetShapeDefinition {",
            "    /// Each preset's adjust values, guides, text rectangle and paths, as the",
            "    /// generator encodes them.",
            "    static let encoded: [String: String] = [",
        ]
    for shape in sorted(root, key=lambda s: s.tag):
        lines.append(f'        "{shape.tag}": "{encode(shape)}",')
    lines += ["    ]", "}", ""]
    output_path = TEXT_WARP_OUTPUT if text_warps else OUTPUT
    with open(output_path, "w") as output:
        output.write("\n".join(lines))
    print(f"Wrote {len(root)} presets to {output_path}")


if __name__ == "__main__":
    main()
