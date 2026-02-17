#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scan_network.sh
# Scannt das lokale Netzwerk mit nmap und schreibt das Ergebnis als
# network_devices.json in das angegebene Ausgabeverzeichnis.
#
# Verwendung:
#   ./scan_network.sh [AUSGABEPFAD]
#
# Beispiel:
#   ./scan_network.sh ../data
#
# Voraussetzungen:
#   - nmap installiert (sudo apt install nmap)
#   - sudo-Rechte für nmap
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ── Konfiguration ─────────────────────────────────────────────────────────────
OUTPUT_DIR="${1:-../data}"
OUTPUT_FILE="${OUTPUT_DIR}/network_devices.json"

# Subnetz automatisch ermitteln und in Netzwerkadresse umwandeln
DETECTED_IP=$(ip -o -f inet addr show | awk '$2 != "lo" {print $4; exit}')

if [[ -z "$DETECTED_IP" ]]; then
  echo "❌  Kein Subnetz gefunden. Bitte SUBNET manuell setzen."
  echo "    Beispiel: SUBNET=192.168.0.0/24 ./scan_network.sh"
  exit 1
fi

# IP und Maske extrahieren (z.B. 192.168.0.99/24)
IP_PART="${DETECTED_IP%/*}"    # Alles vor dem / → 192.168.0.99
MASK_PART="${DETECTED_IP#*/}"  # Alles nach dem / → 24

# Netzwerkadresse: erste 3 Oktette + .0 (vereinfacht für /24 Netze)
NETWORK_BASE="${IP_PART%.*}"   # 192.168.0
SUBNET="${NETWORK_BASE}.0/${MASK_PART}"

# Manuelle Überschreibung möglich
SUBNET="${SUBNET_OVERRIDE:-$SUBNET}"

SCAN_TIME=$(date)

echo ""
echo "🔍  Scanne Netzwerk: ${SUBNET}"
echo "    Ausgabe: ${OUTPUT_FILE}"
echo ""

# ── nmap ausführen ────────────────────────────────────────────────────────────
# Temp-Datei mit vorhersehbarem Namen (nmap läuft als root, braucht Schreibrechte)
XML_TMP="/tmp/netscope_scan_$$.xml"

# Falls alte Datei existiert, aufräumen
sudo rm -f "$XML_TMP"

echo "  nmap läuft (scannt $SUBNET) ..."

# nmap ausführen - läuft als root und erstellt die XML-Datei
NMAP_OUTPUT=$(sudo nmap -sn --resolve-all -oX "$XML_TMP" "$SUBNET" 2>&1)
NMAP_EXIT=$?

if [[ $NMAP_EXIT -ne 0 ]] || [[ ! "$NMAP_OUTPUT" =~ "Nmap done" ]]; then
  echo "❌  nmap-Fehler (Exit: $NMAP_EXIT)"
  echo "$NMAP_OUTPUT" | tail -5
  sudo rm -f "$XML_TMP"
  exit 1
fi

# Prüfen ob XML-Datei Inhalt hat
if [[ ! -s "$XML_TMP" ]]; then
  echo "❌  nmap hat keine Daten geschrieben (XML ist leer)."
  echo "    Temp-Datei: $XML_TMP"
  sudo rm -f "$XML_TMP"
  exit 1
fi

echo "✓  Scan abgeschlossen, verarbeite Ergebnisse …"

# ── XML zu JSON parsen ────────────────────────────────────────────────────────
python3 - "$XML_TMP" "$OUTPUT_FILE" "$SCAN_TIME" << 'PYEOF'
import sys
import json
import xml.etree.ElementTree as ET

xml_file  = sys.argv[1]
out_file  = sys.argv[2]
scan_time = sys.argv[3]

tree = ET.parse(xml_file)
root = tree.getroot()

def guess_device_type(hostname, vendor=""):
    h = hostname.lower()
    v = vendor.lower()
    if any(x in h for x in ["gateway", "router", "fritz", "ubnt", "unifi"]):
        return "Router/Gateway"
    if any(x in h for x in ["diskstation", "synology", "nas", "qnap", "disk"]):
        return "NAS"
    if any(x in h for x in ["sonos"]):
        return "Audio"
    if any(x in h for x in ["shelly", "tasmota", "esp", "tuya", "zigbee"]):
        return "IoT"
    if any(x in h for x in ["homeassistant", "home-assistant", "hass"]):
        return "Home Assistant"
    if any(x in h for x in ["pihole", "pi-hole"]):
        return "Pi-hole"
    if any(x in h for x in ["android", "iphone", "ipad", "pixel", "samsung"]):
        return "Mobile"
    if any(x in h for x in ["appletv", "roku", "chromecast", "shield"]):
        return "Streaming"
    if any(x in v for x in ["raspberry", "synology", "sonos", "shelly"]):
        return "IoT"
    if hostname and hostname != "N/A":
        return "Network Device"
    return "Unknown"

devices = []
for host in root.findall("host"):
    status = host.find("status")
    if status is None or status.get("state") != "up":
        continue

    ip = "N/A"
    for addr in host.findall("address"):
        if addr.get("addrtype") == "ipv4":
            ip = addr.get("addr", "N/A")
            break

    mac = "N/A"
    vendor = ""
    for addr in host.findall("address"):
        if addr.get("addrtype") == "mac":
            mac    = addr.get("addr", "N/A")
            vendor = addr.get("vendor", "")
            break

    hostname = "N/A"
    hostnames = host.find("hostnames")
    if hostnames is not None:
        for hn in hostnames.findall("hostname"):
            name = hn.get("name", "")
            if name:
                hostname = name
                break

    device_type = guess_device_type(hostname, vendor)

    devices.append({
        "ip":       ip,
        "hostname": hostname,
        "mac":      mac,
        "vendor":   vendor if vendor else "N/A",
        "device":   device_type,
        "scan":     scan_time,
    })

def ip_sort_key(d):
    try:
        return tuple(int(p) for p in d["ip"].split("."))
    except Exception:
        return (0, 0, 0, 0)

devices.sort(key=ip_sort_key)

with open(out_file, "w", encoding="utf-8") as f:
    json.dump(devices, f, ensure_ascii=False, indent=2)

print(f"  ✓  {len(devices)} Geräte gefunden → {out_file}")
PYEOF

# Temp-Datei aufräumen (braucht sudo da von nmap als root erstellt)
sudo rm -f "$XML_TMP"

echo ""
echo "✅  network_devices.json aktualisiert."
echo ""