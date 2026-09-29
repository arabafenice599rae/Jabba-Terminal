#!/usr/bin/env python3
"""Genera le tabelle di docs/FORMAL.md da mutation/results.json (vedi mutation/run.py)."""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROPS = ["I1", "I2", "I3", "I4", "I5", "I6", "I7", "I8", "H"]


def prop_of(name):
    """check_I1_receipt / I1_receipt -> I1; check_live_* / live_* -> live."""
    if name == "setUp":
        return "setUp"
    m = re.match(r"(?:check_)?(I\d|H|live)_", name)
    return m.group(1) if m else "?"


def killers(r, tool):
    """Proprietà che rilevano il mutante con un'asserzione violata (le regole vacue sono a parte)."""
    out, vacuous = set(), set()
    for k in r.get("killed_by", []):
        t, name = k.split(":", 1)
        if t != tool:
            continue
        if name.endswith("(vacua)"):
            vacuous.add(prop_of(name[: -len("(vacua)")]))
        else:
            out.add(prop_of(name))
    return out, vacuous


def fmt(props):
    order = PROPS + ["live", "setUp", "?"]
    return ", ".join(sorted(props, key=order.index)) if props else "—"


def main(path=ROOT / "mutation/results.json"):
    res = json.loads(Path(path).read_text())
    res.sort(key=lambda r: (r["kind"] != "mirato", int(re.sub(r"\D", "", r["id"]) or 0), r["id"]))
    lines = []

    # Matrice per proprietà
    lines += ["| Proprietà | Halmos | Certora | Mutanti rilevati (mirati) | Mutanti Gambit rilevati |", "|---|---|---|---|---|"]
    for p in PROPS:
        tg = [r["id"] for r in res if r["kind"] == "mirato" and (p in killers(r, "halmos")[0] | killers(r, "certora")[0])]
        gb = [r["id"] for r in res if r["kind"] == "gambit" and (p in killers(r, "halmos")[0] | killers(r, "certora")[0])]
        lines.append(f"| {p} | ✅ | ✅ | {', '.join(tg) or '—'} | {len(gb)} |")
    lines.append("")

    # Mutanti mirati
    lines += ["| Id | Obiettivo | Mutazione | Halmos | Certora | Esito |", "|---|---|---|---|---|---|"]
    for r in res:
        if r["kind"] != "mirato":
            continue
        h, _ = killers(r, "halmos")
        c, cv = killers(r, "certora")
        cert = fmt(c) + (f" (vacue: {fmt(cv)})" if cv else "")
        lines.append(f"| {r['id']} | {r['target']} | {r['description']} | {fmt(h)} | {cert} | {r['status']} |")
    lines.append("")

    # Riepilogo Gambit
    g = [r for r in res if r["kind"] == "gambit"]
    if g:
        by = {s: sum(1 for r in g if r["status"] == s) for s in ("ucciso", "sopravvissuto", "non compilabile", "errore")}
        h_only = sum(1 for r in g if killers(r, "halmos")[0] and not (killers(r, "certora")[0] | killers(r, "certora")[1]))
        c_only = sum(1 for r in g if (killers(r, "certora")[0] | killers(r, "certora")[1]) and not killers(r, "halmos")[0])
        lines += [
            f"Gambit: {len(g)} mutanti — {by['ucciso']} uccisi, {by['sopravvissuto']} sopravvissuti, "
            f"{by['non compilabile']} non compilabili, {by['errore']} in errore. Rilevati solo da Halmos: {h_only}; solo da Certora: {c_only}.",
            "",
            "| Id | Mutazione | Halmos | Certora | Esito |",
            "|---|---|---|---|---|",
        ]
        for r in g:
            h, _ = killers(r, "halmos")
            c, cv = killers(r, "certora")
            cert = fmt(c) + (f" (vacue: {fmt(cv)})" if cv else "")
            desc = r["description"].replace("|", "\\|")
            lines.append(f"| {r['id']} | `{desc}` | {fmt(h)} | {cert} | {r['status']} |")
    print("\n".join(lines))


if __name__ == "__main__":
    main(*sys.argv[1:])
