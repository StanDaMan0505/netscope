#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scan_all.sh
# Führt beide Scans nacheinander aus und aktualisiert netscope.
#
# Verwendung:
#   ./scan_all.sh [AUSGABEPFAD]
#
# Beispiel:
#   ./scan_all.sh ../data
#
# Optionale Umgebungsvariablen:
#   SUBNET_OVERRIDE=192.168.1.0/24  – Subnetz manuell setzen
#   SKIP_NETWORK=1                  – Netzwerk-Scan überspringen
#   SKIP_DOCKER=1                   – Docker-Scan überspringen
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${1:-../data}"

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║           netscope · Scan                ║"
echo "╚══════════════════════════════════════════╝"
echo "  Ausgabe: ${OUTPUT_DIR}"
echo ""

# Ausgabeverzeichnis sicherstellen
mkdir -p "$OUTPUT_DIR"

START=$(date +%s)

# ── Netzwerk-Scan ─────────────────────────────────────────────────────────────
if [[ "${SKIP_NETWORK:-0}" != "1" ]]; then
  echo "── 1/2  Netzwerk-Scan ───────────────────────"
  SUBNET_OVERRIDE="${SUBNET_OVERRIDE:-}" bash "${SCRIPT_DIR}/scan_network.sh" "$OUTPUT_DIR"
else
  echo "── 1/2  Netzwerk-Scan übersprungen (SKIP_NETWORK=1)"
fi

# ── Docker-Scan ───────────────────────────────────────────────────────────────
if [[ "${SKIP_DOCKER:-0}" != "1" ]]; then
  echo "── 2/2  Docker-Scan ─────────────────────────"
  bash "${SCRIPT_DIR}/scan_docker.sh" "$OUTPUT_DIR"
else
  echo "── 2/2  Docker-Scan übersprungen (SKIP_DOCKER=1)"
fi

END=$(date +%s)
DURATION=$((END - START))

echo "╔══════════════════════════════════════════╗"
echo "║  ✅  Fertig in ${DURATION}s                          ║"
echo "║  Browser-Seite neu laden → aktuell       ║"
echo "╚══════════════════════════════════════════╝"
echo ""
