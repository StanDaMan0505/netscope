#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scan_docker.sh
# Liest alle laufenden Docker-Container aus und schreibt das Ergebnis als
# docker_containers.json in das angegebene Ausgabeverzeichnis.
#
# Verwendung:
#   ./scan_docker.sh [AUSGABEPFAD]
#
# Beispiel:
#   ./scan_docker.sh ../data
#
# Voraussetzungen:
#   - Docker installiert und laufend
#   - User ist in der Gruppe "docker" (oder sudo verfügbar)
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ── Konfiguration ─────────────────────────────────────────────────────────────
OUTPUT_DIR="${1:-../data}"
OUTPUT_FILE="${OUTPUT_DIR}/docker_containers.json"

echo ""
echo "🐳  Lese Docker-Container …"
echo "    Ausgabe: ${OUTPUT_FILE}"
echo ""

# ── Docker-Daten abfragen ─────────────────────────────────────────────────────
DOCKER_RAW=$(docker ps --format '{{.ID}}|{{.Names}}|{{.Image}}|{{.Ports}}|{{.Labels}}' 2>/dev/null)

if [[ -z "$DOCKER_RAW" ]]; then
  echo "⚠️   Keine laufenden Container gefunden (oder kein Docker-Zugriff)."
  echo "[]" > "$OUTPUT_FILE"
  exit 0
fi

# ── Zu JSON verarbeiten ───────────────────────────────────────────────────────
python3 - "$OUTPUT_FILE" << 'PYEOF'
import json
import subprocess
import sys

out_file = sys.argv[1]

result = subprocess.run(
    ["docker", "inspect", "--format",
     "{{json .}}",
     ] + subprocess.run(
        ["docker", "ps", "-q"],
        capture_output=True, text=True
     ).stdout.strip().split("\n"),
    capture_output=True, text=True
)

containers_raw = []
for line in result.stdout.strip().split("\n"):
    line = line.strip()
    if not line:
        continue
    try:
        containers_raw.append(json.loads(line))
    except json.JSONDecodeError:
        continue

containers = []
for c in containers_raw:
    name  = c.get("Name", "").lstrip("/")
    cid   = c.get("Id", "")[:12]
    image = c.get("Config", {}).get("Image", "N/A")

    port_bindings = c.get("HostConfig", {}).get("PortBindings") or {}
    port_parts = []
    for container_port, bindings in port_bindings.items():
        if bindings:
            for b in bindings:
                host_ip   = b.get("HostIp", "0.0.0.0")
                host_port = b.get("HostPort", "")
                if host_ip in ("0.0.0.0", ""):
                    port_parts.append(f"{container_port} -> 0.0.0.0:{host_port}")
    ports_str = "; ".join(port_parts)

    labels = c.get("Config", {}).get("Labels") or {}
    stack  = (
        labels.get("com.docker.compose.project") or
        labels.get("com.docker.stack.namespace") or
        ""
    )

    networks = c.get("NetworkSettings", {}).get("Networks") or {}
    ip = ""
    for net_name, net_info in networks.items():
        candidate = (net_info or {}).get("IPAddress", "")
        if candidate and candidate != "":
            ip = candidate
            break

    containers.append({
        "name":  name,
        "id":    cid,
        "image": image,
        "ports": ports_str,
        "stack": stack,
        "ip":    ip if ip else "N/A",
    })

containers.sort(key=lambda c: (c["stack"].lower(), c["name"].lower()))

with open(out_file, "w", encoding="utf-8") as f:
    json.dump(containers, f, ensure_ascii=False, indent=2)

print(f"  ✓  {len(containers)} Container gefunden → {out_file}")
PYEOF

echo ""
echo "✅  docker_containers.json aktualisiert."
echo ""
