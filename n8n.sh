#!/bin/bash
set -euo pipefail

LOGFILE="/var/log/n8n-install.log"
exec > >(tee -a "$LOGFILE") 2>&1

echo "🔧 Wachten tot apt vrij is..."
while sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
      sudo fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
    sleep 10
done

echo "📦 Pakketbronnen bijwerken..."
apt update -y && apt upgrade -y
apt install -y docker.io docker-compose curl jq dnsutils

DOMAIN=$(hostname -f)
IP=$(hostname -I | awk '{print $1}')

echo "🌍 Controleren van DNS-resolutie..."
RESOLVED_IP=$(dig +short "$DOMAIN" | tail -n1)
if [[ "$RESOLVED_IP" != "$IP" ]]; then
  echo "⚠️  Waarschuwing: $DOMAIN wijst niet naar dit IP ($IP)."
  echo "SSL-aanvraag door Caddy kan tijdelijk falen totdat DNS is bijgewerkt."
fi

mkdir -p /opt/n8n/n8n_data
chown -R 1000:1000 /opt/n8n/n8n_data
chmod -R 700 /opt/n8n/n8n_data
cd /opt/n8n

echo "📝 Docker Compose bestand maken..."

cat <<EOF > docker-compose.yml
version: "3.8"

services:
  caddy:
    image: caddy:latest
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./caddy_data:/data
      - ./caddy_config:/config
    depends_on:
      - n8n

  n8n:
    image: n8nio/n8n:latest
    restart: unless-stopped
    environment:
      - N8N_HOST=$DOMAIN
      - N8N_PROTOCOL=https
      - WEBHOOK_URL=https://$DOMAIN/
      - GENERIC_TIMEZONE=Europe/Amsterdam
      - N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true
    volumes:
      - /opt/n8n/n8n_data:/home/node/.n8n
EOF

cat <<EOF > Caddyfile
$DOMAIN {
  reverse_proxy n8n:5678
}
EOF


echo "🐳 Containers starten..."
docker-compose down || true
docker-compose up -d
systemctl enable docker

echo "✅ n8n installatie voltooid."
echo "🌍 Toegang via: https://$DOMAIN"
