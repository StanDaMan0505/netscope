#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scan_network.sh
# Scannt das lokale Netzwerk/Netze mit nmap und schreibt network_devices.json.
#
# Verwendung:
#   ./scan_network.sh [AUSGABEPFAD]
#
# Steuerung via Umgebung:
#   SUBNET_OVERRIDE="192.168.0.0/24"  → Subnetz manuell setzen (ein Netz)
#   SCAN_ALL_IFACES=1                 → alle aktiven IPv4-Interfaces scannen
#   ENABLE_AGGRESSIVE=1               → -PE -PA -PR -T4 --max-retries 1
#   DNS_SERVERS="192.168.0.1"         → nmap explizit DNS-Server geben
#   ENABLE_NSE=1                      → nmap --script mdns-discovery,nbstat
#
# Abhängigkeiten:
#   - nmap, ip, awk, python3
#   - (optional für Hostnamen): avahi-daemon, libnss-mdns, samba-common-bin, dnsutils
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
die() { echo "❌  $*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Benötigtes Kommando fehlt: $1"; }

need_cmd ip; need_cmd awk; need_cmd nmap; need_cmd python3

# sudo nur wenn nicht root
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then SUDO="sudo"; else SUDO=""; fi

OUTPUT_DIR="${1:-../data}"
OUTPUT_FILE="${OUTPUT_DIR}/network_devices.json"
mkdir -p "$OUTPUT_DIR"

# IPv4-CIDRs aller nicht-loopback-Interfaces
mapfile -t CIDRS < <(ip -o -f inet addr show | awk '$2 != "lo" {print $4}')

if [[ ${#CIDRS[@]} -eq 0 ]]; then
  die "Keine IPv4-Adresse gefunden."
fi

# SUBNETS aufbauen
declare -a SUBNETS=()
if [[ -n "${SUBNET_OVERRIDE:-}" ]]; then
  SUBNETS=("$SUBNET_OVERRIDE")
else
  if [[ "${SCAN_ALL_IFACES:-0}" = "1" && ${#CIDRS[@]} -gt 1 ]]; then
    for DETECTED_IP in "${CIDRS[@]}"; do
      net=$(DETECTED_IP="$DETECTED_IP" python3 - <<'PY'
import ipaddress, os
print(str(ipaddress.ip_interface(os.environ["DETECTED_IP"]).network))
PY
)
      SUBNETS+=("$net")
    done
    # Dedup
    readarray -t SUBNETS < <(printf "%s\n" "${SUBNETS[@]}" | awk '!x[$0]++')
  else
    DETECTED_IP="${CIDRS[0]}"
    net=$(DETECTED_IP="$DETECTED_IP" python3 - <<'PY'
import ipaddress, os
print(str(ipaddress.ip_interface(os.environ["DETECTED_IP"]).network))
PY
)
    SUBNETS=("$net")
  fi
fi

SCAN_TIME="$(date)"

echo ""
echo "🔍  Scanne folgende Subnetze:"
for s in "${SUBNETS[@]}"; do echo "   - $s"; done
echo "    Ausgabe: ${OUTPUT_FILE}"
echo ""

# nmap-Argumente vorbereiten
base_nmap_args=(-sn -R)
if [[ "${ENABLE_AGGRESSIVE:-0}" = "1" ]]; then
  # ICMP Echo, TCP ACK, ARP + schnell + weniger Retries
  base_nmap_args+=(-PE -PA -PR -T4 --max-retries 1)
fi
if [[ -n "${DNS_SERVERS:-}" ]]; then
  base_nmap_args=(--dns-servers "$DNS_SERVERS" "${base_nmap_args[@]}")
fi
if [[ "${ENABLE_NSE:-0}" = "1" ]]; then
  base_nmap_args=(--script mdns-discovery,nbstat "${base_nmap_args[@]}")
fi

# pro Subnetz scannen, XML sammeln
XML_LIST=()
for s in "${SUBNETS[@]}"; do
  XML_TMP="/tmp/netscope_scan_$$-$(echo "$s" | tr '/:' '__').xml"
  $SUDO rm -f "$XML_TMP" 2>/dev/null || true

  echo "  nmap läuft (scannt $s) ..."
  set +e
  NMAP_OUTPUT=$($SUDO nmap "${base_nmap_args[@]}" -oX "$XML_TMP" "$s" 2>&1)
  NMAP_EXIT=$?
  set -e

  if [[ $NMAP_EXIT -ne 0 ]] || [[ ! -s "$XML_TMP" ]]; then
    echo "⚠️  nmap-Problem für $s (Exit $NMAP_EXIT). Fahre fort."
    echo "$NMAP_OUTPUT" | tail -n 12
    $SUDO rm -f "$XML_TMP" || true
  else
    XML_LIST+=("$XML_TMP")
  fi
done

[[ ${#XML_LIST[@]} -gt 0 ]] || die "Kein gültiges nmap-Ergebnis erhalten."

echo "✓  Scan abgeschlossen, verarbeite Ergebnisse …"

python3 - "${XML_LIST[@]}" "$OUTPUT_FILE" "$SCAN_TIME" << 'PYEOF'
import sys, json, socket, subprocess, shutil, re, xml.etree.ElementTree as ET

*XML_FILES, out_file, scan_time = sys.argv[1:]

socket.setdefaulttimeout(1.5)
def which(c): return shutil.which(c) is not None
def run_cmd(cmd, timeout=2.0):
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                           timeout=timeout, check=False, text=True)
        return p.stdout.strip()
    except Exception:
        return ""

FQDN_RE = re.compile(r"^[A-Za-z0-9_.-]+\.[A-Za-z0-9.-]+$")
IP_RE   = re.compile(r"^\d{1,3}(\.\d{1,3}){3}$")

def prefer_name(names):
    seen=set(); norm=[]
    for n in names:
        if not n: continue
        s = n.strip().strip(".")
        if not s or IP_RE.match(s): continue
        k = s.lower()
        if k not in seen:
            seen.add(k); norm.append(s)
    if not norm: return "N/A"
    fqdn = [n for n in norm if FQDN_RE.match(n) and not n.lower().endswith(".local")]
    if fqdn: return fqdn[0]
    dotted = [n for n in norm if "." in n]
    if dotted: return dotted[0]
    return norm[0]

def r_socket(ip):
    try: return socket.gethostbyaddr(ip)[0]
    except Exception: return ""
def r_getent(ip):
    if not which("getent"): return ""
    out = run_cmd(["getent","hosts",ip])
    if out:
        parts = out.split()
        if len(parts)>=2 and parts[0]!=parts[1]:
            return parts[1]
    return ""
def r_avahi(ip):
    if not which("avahi-resolve"): return ""
    out = run_cmd(["avahi-resolve","-a",ip])
    if out and "\t" in out:
        return out.split("\t",1)[1].strip()
    return ""
def r_nmb(ip):
    if not which("nmblookup"): return ""
    out = run_cmd(["nmblookup","-A",ip])
    best=""
    for line in out.splitlines():
        line=line.strip()
        if not line or line.startswith("Looking up") or "MAC Address" in line: continue
        m=re.match(r"^([^\s<]+)\s+<([0-9A-Fa-f]{2})>\s+(\S+)", line)
        if not m: continue
        name, tag, _ = m.groups()
        if tag in ("20","00"):
            best=name
            if tag=="20": break
    return best
def r_dig(ip):
    if not which("dig"): return ""
    out = run_cmd(["dig","+short","-x",ip])
    if out:
        return out.splitlines()[0].strip().rstrip(".")
    return ""

def guess_device_type(hostname, vendor=""):
    h=(hostname or "").lower(); v=(vendor or "").lower()
    if any(x in h for x in ["gateway","router","fritz","ubnt","unifi"]): return "Router/Gateway"
    if any(x in h for x in ["diskstation","synology","nas","qnap","disk"]): return "NAS"
    if "sonos" in h: return "Audio"
    if any(x in h for x in ["shelly","tasmota","esp","tuya","zigbee"]): return "IoT"
    if "homeassistant" in h or "home-assistant" in h or "hass" in h: return "Home Assistant"
    if "pihole" in h or "pi-hole" in h: return "Pi-hole"
    if any(x in h for x in ["android","iphone","ipad","pixel","samsung"]): return "Mobile"
    if any(x in h for x in ["appletv","roku","chromecast","shield"]): return "Streaming"
    if any(x in v for x in ["raspberry","synology","sonos","shelly"]): return "IoT"
    if h and h != "n/a": return "Network Device"
    return "Unknown"

hosts_by_ip = {}

def add_or_merge(dev):
    ip = dev["ip"]
    if ip in hosts_by_ip:
        cur = hosts_by_ip[ip]
        if (cur.get("hostname") in ("N/A","",None)) and (dev.get("hostname") not in ("N/A","",None)):
            cur["hostname"] = dev["hostname"]
        if (cur.get("vendor") in ("N/A","",None)) and dev.get("vendor"):
            cur["vendor"] = dev["vendor"]
        if (cur.get("mac") in ("N/A","",None)) and dev.get("mac"):
            cur["mac"] = dev["mac"]
        return
    hosts_by_ip[ip] = dev

for xml_file in XML_FILES:
    tree = ET.parse(xml_file)
    root = tree.getroot()
    for host in root.findall("host"):
        st = host.find("status")
        if st is None or st.get("state") != "up":
            continue
        ip = "N/A"; mac = "N/A"; vendor = ""
        for addr in host.findall("address"):
            t = addr.get("addrtype")
            if t == "ipv4": ip = addr.get("addr","N/A")
            elif t == "mac":
                mac = addr.get("addr","N/A")
                vendor = addr.get("vendor","") or vendor

        xml_names=[]
        hns=host.find("hostnames")
        if hns is not None:
            for hn in hns.findall("hostname"):
                n=hn.get("name","")
                if n: xml_names.append(n)

        fallbacks=[]
        if ip and ip!="N/A":
            fallbacks.append(r_socket(ip))
            fallbacks.append(r_getent(ip))
            fallbacks.append(r_avahi(ip))
            fallbacks.append(r_nmb(ip))
            fallbacks.append(r_dig(ip))

        hostname = prefer_name(xml_names + fallbacks)
        dev_type = guess_device_type(hostname, vendor)

        dev = {
            "ip": ip, "hostname": hostname, "mac": mac,
            "vendor": vendor if vendor else "N/A",
            "device": dev_type, "scan": scan_time,
        }
        add_or_merge(dev)

devices = list(hosts_by_ip.values())
def ip_sort_key(d):
    try: return tuple(int(p) for p in d["ip"].split("."))
    except: return (0,0,0,0)
devices.sort(key=ip_sort_key)

with open(out_file, "w", encoding="utf-8") as f:
    json.dump(devices, f, ensure_ascii=False, indent=2)

print(f"  ✓  {len(devices)} Geräte gefunden → {out_file}")
PYEOF

# Aufräumen
for x in "${XML_LIST[@]}"; do $SUDO rm -f "$x" 2>/dev/null || true; done

echo ""
echo "✅  network_devices.json aktualisiert."
echo ""