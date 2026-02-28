#!/usr/bin/env bash
# -----------------------------------------------------------------------------
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
#
# Optionale Tools (werden automatisch erkannt und genutzt):
#   - avahi-utils  → mDNS/Bonjour-Auflösung  (sudo apt install avahi-utils)
#   - samba-common → NetBIOS-Auflösung        (sudo apt install samba-common)
#   - dig / host / nslookup → Reverse-DNS     (meist vorinstalliert)
# -----------------------------------------------------------------------------

set -euo pipefail
set +e; echo "DEBUG: errexit vorübergehend aus"; set -u -o pipefail

# -- Konfiguration -------------------------------------------------------------
OUTPUT_DIR="${1:-../data}"
OUTPUT_FILE="${OUTPUT_DIR}/network_devices.json"
mkdir -p "$OUTPUT_DIR"

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

# -- Tool-Erkennung ------------------------------------------------------------
echo ""
echo "🔧  Prüfe verfügbare Tools zur Namensauflösung …"

HAS_DIG=false;       command -v dig            &>/dev/null && HAS_DIG=true || true
HAS_HOST=false;      command -v host           &>/dev/null && HAS_HOST=true || true
HAS_NSLOOKUP=false;  command -v nslookup       &>/dev/null && HAS_NSLOOKUP=true || true
HAS_AVAHI=false;     command -v avahi-resolve  &>/dev/null && HAS_AVAHI=true ||true
HAS_NMBLOOKUP=false; command -v nmblookup      &>/dev/null && HAS_NMBLOOKUP=true || true

echo "    dig:           $(${HAS_DIG}         && echo '✓' || echo '–')"
echo "    host:          $(${HAS_HOST}        && echo '✓' || echo '–')"
echo "    nslookup:      $(${HAS_NSLOOKUP}    && echo '✓' || echo '–')"
echo "    avahi-resolve: $(${HAS_AVAHI}       && echo '✓' || echo '–')"
echo "    nmblookup:     $(${HAS_NMBLOOKUP}   && echo '✓' || echo '–')"
echo ""

echo "🔍  Scanne Netzwerk: ${SUBNET}"
echo "    Ausgabe: ${OUTPUT_FILE}"
echo ""

# -- nmap ausführen ------------------------------------------------------------
XML_TMP="/tmp/netscope_scan_$$.xml"
sudo rm -f "$XML_TMP" 2>/dev/null || true

echo "  nmap läuft (scannt $SUBNET) ..."

# --resolve-all: rDNS für alle Ziele (entspricht -R)
GATEWAY=$(ip route | awk '/default/ {print $3; exit}')
echo "DEBUG GATEWAY: '$GATEWAY'" >&2
DNS_OPT=""
if [[ -n "${GATEWAY:-}" ]]; then
  DNS_OPT="--dns-servers ${GATEWAY}"
fi


NMAP_OUTPUT=$(sudo nmap -sn --resolve-all $DNS_OPT -oX "$XML_TMP" "$SUBNET" 2>&1)
NMAP_EXIT=$?

if [[ $NMAP_EXIT -ne 0 ]] || [[ ! "$NMAP_OUTPUT" =~ "Nmap done" ]]; then
  echo "❌  nmap-Fehler (Exit: $NMAP_EXIT)"
  echo "$NMAP_OUTPUT" | tail -5
  sudo rm -f "$XML_TMP"
  exit 1
fi

if [[ ! -s "$XML_TMP" ]]; then
  echo "❌  nmap hat keine Daten geschrieben (XML ist leer)."
  sudo rm -f "$XML_TMP"
  exit 1
fi

echo "✓  Scan abgeschlossen, ermittle Hostnamen …"
echo ""

# -- Hostnamen für alle gefundenen IPs nachschlagen ----------------------------
# Format: TAB-getrennte Zeilen  →  IP<TAB>hostname
RESOLVED_NAMES=""

# Alle IPs aus der XML-Datei extrahieren
LIVE_IPS=$(sudo grep -oP 'addr="\K[^"]+(?=" addrtype="ipv4")' "$XML_TMP" || true)

for IP in $LIVE_IPS; do
  NAME=""

  # 1. Reverse-DNS via dig
  if [[ -z "$NAME" ]] && $HAS_DIG; then
    NAME=$(dig +short +time=2 +tries=1 -x "$IP" 2>/dev/null | sed 's/\.$//' | head -1)
  fi

  # 2. Reverse-DNS via host
  if [[ -z "$NAME" ]] && $HAS_HOST; then
    NAME=$(host -W 2 "$IP" 2>/dev/null | awk '/domain name pointer/ {sub(/\.$/, "", $NF); print $NF}' | head -1)
  fi

  # 3. Reverse-DNS via nslookup
  if [[ -z "$NAME" ]] && $HAS_NSLOOKUP; then
    NAME=$(nslookup "$IP" 2>/dev/null | awk '/name =/ {sub(/\.$/, "", $NF); print $NF}' | head -1)
  fi

  # 4. mDNS via avahi-resolve
  if [[ -z "$NAME" ]] && $HAS_AVAHI; then
    NAME=$(avahi-resolve -a "$IP" 2>/dev/null | awk '{print $2}' | sed 's/\.local\.$/\.local/' | head -1)
  fi

  # 5. NetBIOS via nmblookup
  if [[ -z "$NAME" ]] && $HAS_NMBLOOKUP; then
    NAME=$(nmblookup -A "$IP" 2>/dev/null \
           | awk '/<00>/ && !/<GROUP>/ {gsub(/[[:space:]]/, "", $1); print $1}' \
           | head -1)
  fi

  # Gefundenen Namen speichern
  if [[ -n "$NAME" ]]; then
    RESOLVED_NAMES="${RESOLVED_NAMES}${IP}    ${NAME}
"
    echo "    ${IP}  →  ${NAME}"
  fi
done

echo ""

# -- XML zu JSON parsen --------------------------------------------------------
python3 - "$XML_TMP" "$OUTPUT_FILE" "$SCAN_TIME" "$RESOLVED_NAMES" << 'PYEOF'
import sys
import json
import xml.etree.ElementTree as ET

xml_file      = sys.argv[1]
out_file      = sys.argv[2]
scan_time     = sys.argv[3]
resolved_raw  = sys.argv[4]

# Aufgelöste Hostnamen in Dict laden  { ip → hostname }
resolved_map = {}
for line in resolved_raw.splitlines():
    parts = line.split("\t", 1)
    if len(parts) == 2:
        resolved_map[parts[0].strip()] = parts[1].strip()

tree = ET.parse(xml_file)
root = tree.getroot()

def guess_device_type(hostname, vendor=""):
    h = hostname.lower()
    v = vendor.lower()
    if any(x in h for x in ["gateway", "router", "fritz", "ubnt", "unifi"]):
        return "Router/Gateway"
    if any(x in h for x in ["diskstation", "synology", "nas", "qnap", "disk"]):
        return "NAS"
    if "sonos" in h:
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
    if any(x in v for x in ["raspberry", "synology", "shelly"]):
        return "IoT"
    if hostname and hostname not in ("N/A", ""):
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

    # 1. Hostname aus nmap-XML (falls vorhanden)
    hostname = ""
    hostnames = host.find("hostnames")
    if hostnames is not None:
        for hn in hostnames.findall("hostname"):
            name = hn.get("name", "").strip()
            if name:
                hostname = name
                break

    # 2. Extern aufgelöster Name (dig / host / nslookup / avahi / nmblookup)
    if not hostname and ip in resolved_map:
        hostname = resolved_map[ip]

    # 3. Fallback: Vendor (wenn bekannt), sonst IP
    if not hostname:
        hostname = vendor if vendor else ip

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

# Temp-Datei aufräumen
sudo rm -f "$XML_TMP" 2>/dev/null || true

echo ""
echo "✅  network_devices.json aktualisiert."
echo ""
