#!/bin/bash

# Проверка, что скрипт запущен от root
if [ "$EUID" -ne 0 ]; then
  echo "Пожалуйста, запустите скрипт от root (или с sudo)."
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
echo "iperf3 iperf3/daemon boolean false" | debconf-set-selections

read -p "Введите доменное имя сервера (например, example.com): " DOMAIN < /dev/tty

read -p "Введите порт для мониторинга (7443 или 8443): " MONITOR_PORT < /dev/tty
if [[ "$MONITOR_PORT" != "7443" && "$MONITOR_PORT" != "8443" ]]; then
  echo "Неверный порт. Будет использован порт 8443 по умолчанию."
  MONITOR_PORT=8443
fi

read -p "Введите путь вебхука бота (например fTCdrLBwRr): " WEBHOOK_PATH < /dev/tty
WEBHOOK_PATH="${WEBHOOK_PATH##/}"
WEBHOOK_PATH="${WEBHOOK_PATH%%/}"

apt update -y
apt install -y nginx python3-pip mtr iperf3
apt remove -y python3-blinker || true

mkdir -p /var/www/site
mkdir -p /root/moni

curl -sL "https://raw.githubusercontent.com/Capybara-z/moni/refs/heads/main/files/index.html" \
     -o /var/www/site/index.html

curl -sL "https://raw.githubusercontent.com/Capybara-z/moni/refs/heads/main/files/moni.py" \
     -o /root/moni/moni.py

sed -i "s|__WEBHOOK_PATH__|/${WEBHOOK_PATH}|g" /root/moni/moni.py

NGINX_CONFIG="/etc/nginx/sites-available/monitoring.conf"
cat > "$NGINX_CONFIG" <<EOF
server {
    listen 80;
    server_name ${DOMAIN};

    if ($host = ${DOMAIN}) {
        return 301 https://$host$request_uri;
    } 

    return 404;
}

server {
    listen 127.0.0.1:${MONITOR_PORT} ssl http2 proxy_protocol;
    server_name ${DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:...:ECDHE-RSA-CHACHA20-POLY1305';
    ssl_session_cache shared:SSL:1m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    real_ip_header proxy_protocol;
    set_real_ip_from 127.0.0.1;
    set_real_ip_from ::1;

    root /var/www/site;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location /${WEBHOOK_PATH}/ {
        proxy_pass http://localhost:61016;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

ln -sf "$NGINX_CONFIG" /etc/nginx/sites-enabled/monitoring.conf
nginx -t && systemctl reload nginx

pip3 install Flask psutil requests --break-system-packages

cat > /etc/systemd/system/moni.service <<EOF
[Unit]
Description=Flask Service
After=network.target

[Service]
ExecStart=/usr/bin/python3 /root/moni/moni.py
Restart=always
User=root
WorkingDirectory=/root/moni
Environment="PYTHONUNBUFFERED=1"

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable moni.service
systemctl start moni.service

echo "===== Установка завершена ====="
echo "sudo systemctl status moni.service"
