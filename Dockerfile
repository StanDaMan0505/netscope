FROM nginx:alpine

# nginx.conf und index.html direkt ins Image kopieren
COPY nginx.conf /etc/nginx/nginx.conf
COPY data/index.html /usr/share/nginx/html/index.html

# Kein root nötig – nginx läuft als unprivilegierter User
USER 1000:1000
