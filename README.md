# netscope 🔭

**Minimales Docker-basiertes Dashboard für Netzwerk- und Container-Inventarisierung.**

Visualisiert deine Infrastruktur – welche Geräte sind im Netzwerk, welche Docker-Container laufen wo? Alles auf einen Blick, mit live-Filterung, klickbaren Stacks und null Overhead.

---

## ✨ Features

- **Netzwerk-Scan**: Automatische Erkennung aller Geräte im lokalen Netz via nmap
- **Docker-Inventar**: Zeigt alle laufenden Container mit Ports, Images und Stacks
- **Live-Filter**: Klick auf Stacks oder Gerätetypen zum sofortigen Filtern
- **Zero-Config**: Nur JSON-Dateien kopieren → Browser neu laden → fertig
- **Minimal**: nginx:alpine als Webserver, kein Build-Schritt nötig

---

## 📸 Screenshot

<img width="1493" height="758" alt="image" src="https://github.com/user-attachments/assets/c11a98c9-f595-40d8-ad39-36570ffa1db2" />


---

## 🚀 Schnellstart

### Voraussetzungen

- Docker & Docker Compose installiert
- nmap installiert: `sudo apt install nmap`
- User in der Gruppe `docker`: `sudo usermod -aG docker $USER`

### Installation

```bash
# Repository klonen
git clone https://github.com/StanDaMan0505/netscope.git
cd netscope

# Environment-Variablen anpassen (optional)
cp .env.example .env
# Editiere .env bei Bedarf (Port, Pfad)

# Container starten
docker compose up -d

# Dashboard öffnen
http://localhost:8080
```

---

## 📊 Daten aktualisieren

Die Scan-Skripte erzeugen die JSON-Dateien, die das Dashboard anzeigt:

```bash
# Alles scannen (Netzwerk + Docker)
cd scripts/
./scan_all.sh

# Nur Netzwerk scannen
./scan_network.sh

# Nur Docker scannen
./scan_docker.sh

# Mit eigenem Subnetz
SUBNET_OVERRIDE=192.168.1.0/24 ./scan_all.sh
```

Die Skripte schreiben standardmäßig nach `../data/` – das Dashboard lädt die Daten sofort nach Browser-Reload.

---

## ⚙️ Konfiguration

### Environment-Variablen (`.env`)

| Variable             | Standard  | Beschreibung                        |
|----------------------|-----------|-------------------------------------|
| `NETSCOPE_PORT`      | `8080`    | Externer Port für das Dashboard     |
| `NETSCOPE_DATA_DIR`  | `./data`  | Pfad zum Daten-Verzeichnis          |

### Subnetz anpassen

Die Skripte erkennen automatisch dein lokales Subnetz. Für manuelle Konfiguration:

```bash
# Als Umgebungsvariable
SUBNET_OVERRIDE=10.0.0.0/24 ./scripts/scan_network.sh

# Oder im Skript hardcoden (nicht empfohlen für GitHub)
```

---

## 📁 Verzeichnisstruktur

```
netscope/
├── README.md                     # Diese Datei
├── LICENSE                       # MIT License
├── .gitignore                    # Ignoriert .env und JSON-Daten
├── Dockerfile                    # Optional: Image-Build
├── docker-compose.yml            # Stack-Definition
├── .env.example                  # Beispiel-Konfiguration
├── nginx.conf                    # Webserver-Konfiguration
├── data/                         # Daten-Verzeichnis (gemountet)
│   ├── index.html                # Dashboard-Template
│   ├── network_devices.json      # Generiert von scan_network.sh
│   └── docker_containers.json    # Generiert von scan_docker.sh
└── scripts/                      # Scan-Skripte
    ├── scan_all.sh               # Führt beide Scans aus
    ├── scan_network.sh           # Nmap-Scan
    └── scan_docker.sh            # Docker-Inventar
```

---

## 🐳 Verwendung mit Portainer

Portainer Stacks können nicht bauen – verwende stattdessen die Compose-Datei direkt:

1. **Ohne Dockerfile** – verwende die bereitgestellte `docker-compose.yml` (mountet `nginx.conf` als Volume)
2. **Oder Image extern bauen**:
   ```bash
   docker build -t netscope:latest .
   # Dann in Portainer Stack: nur image: netscope:latest nutzen
   ```

---

## 🔄 Automatisierung

### Cron-Job für tägliche Scans

```bash
# Crontab editieren
crontab -e

# Täglich um 3 Uhr morgens scannen
0 3 * * * cd /pfad/zu/netscope/scripts && ./scan_all.sh
```

### Systemd-Timer (Alternative)

Siehe [docs/systemd-timer.md](docs/systemd-timer.md) *(optional, später hinzufügen)*

---

## 🎨 Anpassungen

### Dashboard-Design ändern

Die `data/index.html` ist vollständig selbst-contained – alle Styles und JavaScript sind eingebettet. Editiere die Datei direkt und lade den Container neu:

```bash
docker compose restart
```

### Gerätetyp-Erkennung erweitern

Editiere `scripts/scan_network.sh`, Funktion `guess_device_type()`:

```python
if any(x in h for x in ["mein-gerät", "custom-device"]):
    return "Mein Custom Typ"
```

---

## 🛠️ Entwicklung

### Lokaler Test ohne Docker

```bash
# index.html muss über einen Webserver laufen (nicht file://)
python3 -m http.server 8080 --directory data/
# Browser: http://localhost:8080
```

### Image lokal bauen

```bash
docker build -t netscope:latest .
docker run -p 8080:80 -v $(pwd)/data:/usr/share/nginx/html:ro netscope:latest
```

---

## 🤝 Beitragen

Pull Requests sind willkommen! Für größere Änderungen bitte erst ein Issue öffnen.

### Checklist für PRs:
- [ ] Code funktioniert lokal
- [ ] Keine hardcoded Pfade oder IPs
- [ ] README aktualisiert falls nötig
- [ ] `.gitignore` respektiert

---

## 📝 Lizenz

[MIT](LICENSE) – siehe LICENSE-Datei für Details.

---

## 🙏 Credits

Entwickelt mit ❤️ für einfache Infrastruktur-Übersicht.

**Tech Stack:**
- [nginx:alpine](https://hub.docker.com/_/nginx) – Webserver
- [nmap](https://nmap.org/) – Netzwerk-Scanning
- Vanilla JS – kein Framework-Overhead
- [DM Sans / DM Serif Display](https://fonts.google.com/) – Typografie
