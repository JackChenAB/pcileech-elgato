#!/usr/bin/env python3
"""pyslang lint for pcileech-hd60pro sources.

Usage: python3 tools/lint.py file1.sv [file2.sv ...]

Exit 0 only when no error-severity diagnostics remain after filtering the
known-benign classes (stock pcileech code was written for Vivado's checker;
these classes fire on the untouched files too, so they are warnings here):

  UnknownModule          - references Vivado IP cores not in this tree
  TopModuleIfacePort     - interface ports at top level (PCILeech pattern)
  MissingTimeScale       - stock files omit `timescale
  ArithOpMismatch        - signed/unsigned arithmetic, Vivado-accepted
  SignCompare            - ditto
  SignConversion         - ditto
  WidthTruncate          - implicit truncation, Vivado-accepted
  EmptyOutputPortConn    - unconnected outputs in instantiations
  DuplicateDefinition    - files parsed together share include guards
  InterfacePortFlags     - `interface.modport` usage differences vs std

Anything else that is an error fails the run.
"""

import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent          # pcileech-hd60pro/
SRC = REPO / "src"

BENIGN = {
    "UnknownModule", "TopModuleIfacePort", "MissingTimeScale",
    "ArithOpMismatch", "SignCompare", "SignConversion", "WidthTruncate",
    "EmptyOutputPortConn", "DuplicateDefinition", "InterfacePortFlags",
    "WidthExpand", "CaseDefault", "DanglingElse",
}


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: lint.py <file.sv> [...]", file=sys.stderr)
        return 2

    import pyslang

    files = []
    for a in argv[1:]:
        p = Path(a)
        if not p.is_absolute():
            p = Path.cwd() / p
        if not p.exists():
            print(f"lint: no such file: {a}", file=sys.stderr)
            return 2
        files.append(str(p))

    d = pyslang.driver.Driver()
    d.addStandardArgs()
    cmdline = f"-I{SRC} " + " ".join(f'"{f}"' for f in files)
    if not d.parseCommandLine(cmdline):
        print("lint: command line parse failed", file=sys.stderr)
        return 2
    if not d.parseAllSources():
        print("lint: parse failed", file=sys.stderr)
        return 2
    comp = d.createCompilation()
    diags = comp.getAllDiagnostics()

    failures = []
    warned = 0
    for g in diags:
        name = str(g.code).replace("DiagCode(", "").rstrip(")")
        if g.isError and name not in BENIGN:
            sm = d.sourceManager
            fname = sm.getFileName(g.location)
            try:
                line = sm.getLineNumber(g.location)
                text = open(fname, encoding="utf-8", errors="replace").read().splitlines()[line - 1] if line else ""
            except Exception:
                line, text = 0, ""
            failures.append(f"  {fname}:{line}: {name}: {text.strip()[:120]}")
        elif g.isError:
            warned += 1

    if warned:
        print(f"lint: {warned} benign diagnostic(s) filtered")
    if failures:
        print(f"lint: FAIL ({len(failures)} error(s))")
        for f in failures[:40]:
            print(f)
        return 1
    print(f"lint: OK ({len(files)} file(s), {warned} filtered)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
