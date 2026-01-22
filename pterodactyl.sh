#!/bin/bash
set -euo pipefail

LOG="/var/log/pterodactyl-install.log"
exec > >(tee -a "$LOG") 2>&1

# ---------- Basis & locks ----------
export DEBIAN_FRONTEND=noninteractive
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do sleep 5; done
apt update -y && apt upgrade -y

# ---------- Variabelen ----------
FQDN="$(hostname -f)"
TZ="Europe/Amsterdam"
PANEL_DIR="/var/www/pterodactyl"
DB_NAME="pterodactyl"
DB_USER="pterodactyl"
DB_PASS="$(openssl rand -base64 24)"
ADMIN_EMAIL="admin@${FQDN}"
ADMIN_USER="admin"
ADMIN_PASS="$(openssl rand -base64 18)"

# ---------- Vereiste pakketten (Panel stack) ----------
apt install -y curl gnupg2 ca-certificates lsb-release software-properties-common \
               ufw unzip zip tar git redis-server \
               mariadb-server mariadb-client \
               nginx certbot python3-certbot-nginx \
               php8.2 php8.2-{fpm,cli,gd,mbstring,tokenizer,bcmath,xml,curl,zip,pgsql,mysql,redis,readline,intl,sqlite3,common,imagick} \
               composer

# ---------- Firewall ----------
ufw allow 22/tcp || true
ufw allow 80,443/tcp || true
ufw --force enable || true

# ---------- MariaDB: database & user ----------
systemctl enable --now mariadb
mysql -u root <<SQL
CREATE DATABASE IF NOT EXISTS ${DB_NAME} DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL

# ---------- Panel downloaden & installeren ----------
mkdir -p "${PANEL_DIR}"
cd "${PANEL_DIR}"

# Laatste release ophalen
curl -L https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz -o panel.tar.gz
tar -xzf panel.tar.gz
rm -f panel.tar.gz

if [ ! -f .env.example ]; then
  echo "ERROR: .env.example ontbreekt. Inhoud van ${PANEL_DIR}:"
  ls -la
  exit 1
fi


cp .env.example .env
composer install --no-dev --optimize-autoloader

# APP key en config .env
php artisan key:generate --force
php -r "
\$env = file_get_contents('.env');
\$env = preg_replace('/APP_URL=.*/', 'APP_URL=https://${FQDN}', \$env);
\$env = preg_replace('/APP_TIMEZONE=.*/', 'APP_TIMEZONE=${TZ}', \$env);
\$env = preg_replace('/DB_HOST=.*/', 'DB_HOST=127.0.0.1', \$env);
\$env = preg_replace('/DB_PORT=.*/', 'DB_PORT=3306', \$env);
\$env = preg_replace('/DB_DATABASE=.*/', 'DB_DATABASE=${DB_NAME}', \$env);
\$env = preg_replace('/DB_USERNAME=.*/', 'DB_USERNAME=${DB_USER}', \$env);
\$env = preg_replace('/DB_PASSWORD=.*/', 'DB_PASSWORD=${DB_PASS}', \$env);
file_put_contents('.env', \$env);
"

php artisan migrate --force
php artisan p:user:make --email="${ADMIN_EMAIL}" --username="${ADMIN_USER}" --name-first="Admin" --name-last="User" --password="${ADMIN_PASS}" --admin=1

# Permissies (zoals docs voorschrijven)
chown -R www-data:www-data "${PANEL_DIR}"
find "${PANEL_DIR}" -type f -exec chmod 644 {} \;
find "${PANEL_DIR}" -type d -exec chmod 755 {} \;

# ---------- Queue worker (pteroq) ----------
cat > /etc/systemd/system/pteroq.service <<'UNIT'
[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service
Requires=redis-server.service

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php /var/www/pterodactyl/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
StartLimitInterval=180
StartLimitBurst=30

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now pteroq

# ---------- Nginx vhost ----------
cat > /etc/nginx/sites-available/pterodactyl.conf <<NGINX
server {
    listen 80;
    server_name ${FQDN};
    root ${PANEL_DIR}/public;

    index index.php;
    charset utf-8;

    client_max_body_size 100m;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.2-fpm.sock;
        fastcgi_param PHP_VALUE "upload_max_filesize=100M \n post_max_size=100M";
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico)$ {
        expires max;
        log_not_found off;
    }
}
NGINX

ln -sf /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf
rm -f /etc/nginx/sites-enabled/default || true
nginx -t && systemctl reload nginx
systemctl enable --now php8.2-fpm

# ---------- Let's Encrypt ----------
certbot --nginx -d "${FQDN}" --non-interactive --agree-tos -m "${ADMIN_EMAIL}" || true
nginx -t && systemctl reload nginx

# ---------- Wings (daemon) ----------
# Docker en dependencies voor Wings
apt install -y docker.io
systemctl enable --now docker

# Wings binary volgens docs
WINGS_URL="$(curl -s https://api.github.com/repos/pterodactyl/wings/releases/latest | grep browser_download_url | grep linux_amd64 | cut -d '"' -f 4)"
mkdir -p /etc/pterodactyl /var/lib/pterodactyl
curl -L "$WINGS_URL" -o /usr/local/bin/wings
chmod +x /usr/local/bin/wings

# Voorbereide (lege) config, die je straks vanuit het Panel (Nodes) vervangt
cat > /etc/pterodactyl/config.yml <<'CFG'
# Plaats hier straks de inhoud van de "Configuration" uit het Panel (Nodes -> jouw node -> Configuration).
# Deze file wordt door systemd/wings gebruikt.
CFG

# systemd unit voor Wings
cat > /etc/systemd/system/wings.service <<'UNIT'
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service
Wants=network-online.target

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=4096
PIDFile=/var/run/wings/daemon.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
# We starten Wings pas als er een geldige config aanwezig is:
systemctl disable wings || true

# ---------- Helper om Wings snel te koppelen ----------
cat > /usr/local/bin/ptero-wings-apply <<'HELP'
#!/bin/bash
set -euo pipefail
CONF="/etc/pterodactyl/config.yml"
if [ $# -gt 0 ]; then
  # 1) Token-URL of config-download link geplakt als argument
  curl -fsSL "$1" -o "$CONF"
else
  # 2) Lees YAML van stdin (Panel -> Nodes -> Configuration -> copy/paste)
  cat > "$CONF"
fi
chmod 600 "$CONF"
systemctl enable --now wings
echo "Wings gestart. Status:"
systemctl --no-pager status wings | sed -n '1,15p'
HELP
chmod +x /usr/local/bin/ptero-wings-apply

# ---------- Samenvatting ----------
cat > /root/pterodactyl_summary.txt <<EOF
========================================
Pterodactyl installatie voltooid
----------------------------------------
Panel URL : https://${FQDN}
Admin user: ${ADMIN_USER}
Admin mail: ${ADMIN_EMAIL}
Admin pass: ${ADMIN_PASS}

DB name   : ${DB_NAME}
DB user   : ${DB_USER}
DB pass   : ${DB_PASS}

Wings     : geïnstalleerd (Docker actief)
Config    : /etc/pterodactyl/config.yml (nog invullen)
Helper    : ptero-wings-apply  (plak Config uit Panel of geef URL)

Logbestand: ${LOG}
========================================
EOF

echo "Klaar. Zie /root/pterodactyl_summary.txt"
