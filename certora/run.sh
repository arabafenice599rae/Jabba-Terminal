#!/usr/bin/env bash
# Esegue il Certora Prover open source in locale sulle regole I1–I8.
#   certora/run.sh [argomenti extra di certoraRun, es. --rule I1_receipt]
# Requisiti: CERTORA (build locale del Prover, con emv.jar e certoraRun.py), solc-0.8.36 nel PATH
# (Certora supporta solc fino a 0.8.36 con via-IR; il pragma ^0.8.35 lo consente).
set -euo pipefail
cd "$(dirname "$0")/.."
: "${CERTORA:?imposta CERTORA alla directory della build del Prover}"
export PATH="$CERTORA:$PATH"  # tac_optimizer
# L'SDK AWS interno al Prover non interpreta le voci IPv6 di NO_PROXY.
strip_ipv6() { printf '%s' "${1:-}" | tr ',' '\n' | grep -v ':' | paste -sd, - || true; }
export NO_PROXY="$(strip_ipv6 "${NO_PROXY:-}")" no_proxy="$(strip_ipv6 "${no_proxy:-}")"
exec python3 "$CERTORA/certoraRun.py" certora/jabba.conf "$@"
