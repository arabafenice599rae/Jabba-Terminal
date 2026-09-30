#!/usr/bin/env python3
"""Mutation testing delle proprietà formali di Jabba (§12, passo 8).

Per ogni mutante di src/Jabba.sol (mirati da mutation/targeted.json e/o generati da Gambit)
esegue i check Halmos e le regole Certora in una copia isolata del repo, e registra quali
proprietà lo rilevano. Un mutante è "ucciso" se almeno una proprietà fallisce.

Uso:
  mutation/run.py --targeted                     # solo mutazioni mirate
  mutation/run.py --gambit                       # genera ed esegue i mutanti Gambit
  mutation/run.py --targeted --gambit --jobs 2   # tutto, due mutanti in parallelo
Opzioni: --no-certora / --no-halmos, --only T1,T5,g12, --out mutation/results.json, --resume

Requisiti: forge, halmos, gambit, CERTORA (build locale del Prover), solc-0.8.36 nel PATH.
"""
import argparse
import concurrent.futures as cf
import glob
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TARGET = "src/Jabba.sol"
HALMOS_RE = re.compile(r"\[(PASS|FAIL|ERROR|TIMEOUT)\]\s+(\w+)\(")
ANSI = re.compile(r"\x1b\[[0-9;]*m")


def sh(cmd, cwd, timeout, env=None):
    # Nuova sessione: allo scadere del timeout si termina l'intero gruppo (sh e figli, es. halmos).
    p = subprocess.Popen(cmd, cwd=cwd, env=env, shell=True, text=True, start_new_session=True,
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    try:
        out, _ = p.communicate(timeout=timeout)
        return p.returncode, ANSI.sub("", out)
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL)
        out, _ = p.communicate()
        return 124, ANSI.sub("", out or "")


def load_targeted():
    src = (ROOT / TARGET).read_text()
    mutants = []
    for m in json.loads((ROOT / "mutation/targeted.json").read_text()):
        code = src
        for old, new in m["edits"]:
            if old not in code:
                sys.exit(f"{m['id']}: testo da mutare non trovato: {old!r}")
            code = code.replace(old, new, 1)
        mutants.append({"id": m["id"], "kind": "mirato", "target": m["target"], "description": m["description"], "code": code})
    return mutants


def load_gambit(workdir):
    gdir = Path(workdir) / "gambit"
    (gdir / "src").mkdir(parents=True, exist_ok=True)
    shutil.copy(ROOT / TARGET, gdir / TARGET)
    rc, out = sh(
        f"gambit mutate --filename {TARGET} --contract Jabba --solc solc-0.8.36 --solc_optimize "
        f"--solc_evm_version osaka -o out",
        gdir,
        600,
    )
    if rc != 0:
        sys.exit("gambit fallito:\n" + out)
    mutants = []
    for m in json.loads((gdir / "out/gambit_results.json").read_text()):
        diff_lines = [l for l in m["diff"].splitlines() if l[:1] in "+-" and not l.startswith(("+++", "---"))]
        mutants.append({
            "id": f"g{m['id']}",
            "kind": "gambit",
            "target": "",
            "description": f"{m['description']}: " + " / ".join(l.strip() for l in diff_lines),
            "code": (gdir / "out" / m["name"]).read_text(),
        })
    return mutants


def make_workspace(base):
    ws = Path(tempfile.mkdtemp(prefix="jabba-mut-", dir=base))
    for item in ["src", "test", "script", "certora", "foundry.toml"]:
        s = ROOT / item
        (shutil.copytree if s.is_dir() else shutil.copy)(s, ws / item)
    os.symlink(ROOT / "lib", ws / "lib")
    return ws


def run_halmos(ws):
    rc, out = sh("forge build --ast -q", ws, 900)
    if rc != 0:
        return None, out
    rc, out = sh("halmos --contract JabbaHalmos --loop 8 --solver-timeout-assertion 60000", ws, 600)
    if rc == 124:
        return {"timeout": "TIMEOUT"}, out
    res = {name: status for status, name in HALMOS_RE.findall(out)}
    return res, out


def run_certora(ws, tag):
    for d in glob.glob(str(ws / "emv-*")) + [str(ws / ".certora_internal")]:
        shutil.rmtree(d, ignore_errors=True)
    rc, out = sh(f"certora/run.sh --msg {tag}", ws, 900)
    reports = glob.glob(str(ws / "emv-*/Reports/output.json"))
    if not reports:
        return None, out
    # Motivo del fallimento: asserzione violata oppure regola vacua (nessun percorso che non fa revert).
    reasons = {}
    for rule, msg in re.findall(r"^Result for (\w+): .*?FAIL: (.*)$", out, re.M):
        reasons.setdefault(rule, []).append(msg.strip())
    res = {}
    for rule, v in json.loads(Path(reports[0]).read_text())["rules"].items():
        if rule == "envfreeFuncsStaticCheck":
            continue
        statuses = {v} if isinstance(v, str) else set(v)
        # SANITY_FAIL: la regola è vacua (nessun percorso raggiunge le asserzioni senza revert).
        status = "SUCCESS" if statuses == {"SUCCESS"} else ("FAIL" if "FAIL" in statuses else "VACUOUS")
        if status != "SUCCESS":
            if re.search(r"vacu|sanity", " ".join(reasons.get(rule, [])), re.I):
                status = "VACUOUS"
        res[rule] = status
        if rule in reasons:
            res[rule + "#msg"] = reasons[rule]
    return res, out


def evaluate(m, base, do_halmos, do_certora):
    ws = make_workspace(base)
    try:
        (ws / TARGET).write_text(m["code"])
        t0 = time.time()
        r = {k: m[k] for k in ("id", "kind", "target", "description")}
        rc, out = sh("solc-0.8.36 --optimize --evm-version osaka src/Jabba.sol", ws, 120)
        if rc != 0:
            r["status"] = "non compilabile"
            return r
        if do_halmos:
            r["halmos"], log = run_halmos(ws)
            if r["halmos"] is None:
                r["status"] = "non compilabile"
                r["log"] = log[-2000:]
                return r
        if do_certora:
            r["certora"], log = run_certora(ws, m["id"])
            if r["certora"] is None:
                r["certora_error"] = log[-2000:]
        # TIMEOUT di Halmos (intero run o singolo check) non è una rilevazione.
        killers = [f"halmos:{k}" for k, v in (r.get("halmos") or {}).items() if v not in ("PASS", "TIMEOUT")]
        if do_halmos and not r["halmos"]:  # {"timeout": ...} non è vuoto
            killers.append("halmos:setUp")  # nessun check eseguito: il deploy di setUp fallisce
        killers += [
            f"certora:{k}" + ("(vacua)" if v == "VACUOUS" else "")
            for k, v in (r.get("certora") or {}).items()
            if "#" not in k and v != "SUCCESS"
        ]
        r["killed_by"] = killers
        if do_certora and not r.get("certora") and not killers:
            r["status"] = "errore"  # Certora senza risultati: da rieseguire
        else:
            r["status"] = "ucciso" if killers else "sopravvissuto"
        r["seconds"] = round(time.time() - t0)
        return r
    finally:
        shutil.rmtree(ws, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--targeted", action="store_true")
    ap.add_argument("--gambit", action="store_true")
    ap.add_argument("--no-halmos", action="store_true")
    ap.add_argument("--no-certora", action="store_true")
    ap.add_argument("--only", default="")
    ap.add_argument("--jobs", type=int, default=1)
    ap.add_argument("--out", default=str(ROOT / "mutation/results.json"))
    ap.add_argument("--resume", action="store_true", help="salta i mutanti già presenti in --out")
    a = ap.parse_args()

    base = tempfile.mkdtemp(prefix="jabba-mutation-")
    mutants = (load_targeted() if a.targeted else []) + (load_gambit(base) if a.gambit else [])
    if a.only:
        keep = set(a.only.split(","))
        mutants = [m for m in mutants if m["id"] in keep]
    results = []
    if a.resume and Path(a.out).exists():
        results = json.loads(Path(a.out).read_text())
        done = {r["id"] for r in results}
        mutants = [m for m in mutants if m["id"] not in done]
    print(f"{len(mutants)} mutanti da eseguire ({len(results)} già fatti)", flush=True)

    with cf.ThreadPoolExecutor(max_workers=a.jobs) as ex:
        futs = {ex.submit(evaluate, m, base, not a.no_halmos, not a.no_certora): m for m in mutants}
        for f in cf.as_completed(futs):
            r = f.result()
            results.append(r)
            print(f"{r['id']:>5} {r['status']:<16} {', '.join(r.get('killed_by', []))}", flush=True)
            Path(a.out).write_text(json.dumps(sorted(results, key=lambda r: r["id"]), indent=2, ensure_ascii=False))
    shutil.rmtree(base, ignore_errors=True)


if __name__ == "__main__":
    main()
