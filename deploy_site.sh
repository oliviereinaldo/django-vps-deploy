#!/bin/bash
set -euo pipefail

# ================================
# VARIÁVEIS BÁSICAS
# ================================
read -rp "Nome do site (ex: meusite): " NOME_SITE
read -rp "Domínio (ex: meusite.com): " DOMINIO
read -rp "Email Certbot: " EMAIL_CERTBOT

DOMINIO_WWW="www.$DOMINIO"
PROJETO="core"
APP="principal"
SITE_DIR="/var/www/$NOME_SITE"
SERVICE_NAME="$NOME_SITE"

DB_NAME="${NOME_SITE}_db"
DB_USER="usr_${NOME_SITE}"
DB_PASS=$(openssl rand -base64 16)

# ================================
# DEPENDÊNCIAS DO SISTEMA
# ================================
sudo apt update
sudo apt install -y \
  python3 python3-venv python3-pip python3-setuptools \
  nginx mysql-server mysql-client \
  default-libmysqlclient-dev build-essential pkg-config \
  certbot python3-certbot-nginx

# ================================
# BANCO DE DADOS
# ================================
sudo mysql <<EOF
CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF

# ================================
# DIRETÓRIO DO SITE
# ================================
sudo rm -rf "$SITE_DIR"
sudo mkdir -p "$SITE_DIR"
sudo chown "$USER:$USER" "$SITE_DIR"
cd "$SITE_DIR"

# ================================
# AMBIENTE VIRTUAL
# ================================
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install django gunicorn mysqlclient python-dotenv

# ================================
# PROJETO DJANGO
# ================================
django-admin startproject "$PROJETO" .
python manage.py startapp "$APP"

# ================================
# SETTINGS.PY
# ================================
SETTINGS="$SITE_DIR/$PROJETO/settings.py"

sed -i "s/DEBUG = True/DEBUG = False/" "$SETTINGS"
sed -i "/ALLOWED_HOSTS/d" "$SETTINGS"
echo "ALLOWED_HOSTS = ['$DOMINIO', '$DOMINIO_WWW']" >> "$SETTINGS"

sed -i "/SECRET_KEY =/d" "$SETTINGS"

cat <<EOF >> "$SETTINGS"

import os

SECRET_KEY = os.getenv("SECRET_KEY_DJANGO")

DATABASES = {
    "default": {
        "ENGINE": "django.db.backends.mysql",
        "NAME": os.getenv("DB_NAME"),
        "USER": os.getenv("DB_USER"),
        "PASSWORD": os.getenv("DB_PASS"),
        "HOST": "localhost",
        "PORT": "3306",
    }
}

STATIC_ROOT = BASE_DIR / "staticfiles"

LOGGING = {
    "version": 1,
    "disable_existing_loggers": False,
    "handlers": {
        "console": {"class": "logging.StreamHandler"},
    },
    "root": {
        "handlers": ["console"],
        "level": "INFO",
    },
}
EOF

# ================================
# APP BÁSICO
# ================================
sed -i "/INSTALLED_APPS = \[/a\    '$APP'," "$SETTINGS"

mkdir -p "$APP/templates/$APP"
mkdir -p "$APP/static/$APP/css"

cat <<EOF > "$APP/templates/$APP/home.html"
<!DOCTYPE html>
<html lang="pt-BR">
<head>
  <meta charset="UTF-8">
  <title>Home</title>
  {% load static %}
  <link rel="stylesheet" href="{% static '$APP/css/home.css' %}">
</head>
<body>
  <h1>🚀 Site em produção</h1>
</body>
</html>
EOF

cat <<EOF > "$APP/static/$APP/css/home.css"
body {
  font-family: Arial, sans-serif;
  background: #0f172a;
  color: #fff;
  display: flex;
  justify-content: center;
  align-items: center;
  height: 100vh;
}
EOF

cat <<EOF > "$APP/views.py"
from django.shortcuts import render

def home(request):
    return render(request, "$APP/home.html")
EOF

cat <<EOF > "$APP/urls.py"
from django.urls import path
from .views import home

urlpatterns = [
    path("", home),
]
EOF

sed -i "s/from django.urls import path/from django.urls import path, include/" "$PROJETO/urls.py"
sed -i "/urlpatterns = \[/a\    path('', include('$APP.urls'))," "$PROJETO/urls.py"

# ================================
# VARIÁVEIS DE AMBIENTE
# ================================
SECRET_KEY_DJANGO=$(python - <<EOF
from django.core.management.utils import get_random_secret_key
print(get_random_secret_key())
EOF
)

sudo tee "/etc/$NOME_SITE.env" > /dev/null <<EOF
SECRET_KEY_DJANGO=$SECRET_KEY_DJANGO
DB_NAME=$DB_NAME
DB_USER=$DB_USER
DB_PASS=$DB_PASS
EOF

# ================================
# STATIC FILES
# ================================
python manage.py collectstatic --noinput

# ================================
# GUNICORN SERVICE
# ================================
sudo tee "/etc/systemd/system/$SERVICE_NAME.service" > /dev/null <<EOF
[Unit]
Description=Gunicorn $NOME_SITE
After=network.target

[Service]
User=www-data
Group=www-data
WorkingDirectory=$SITE_DIR
EnvironmentFile=/etc/$NOME_SITE.env
ExecStart=$SITE_DIR/venv/bin/gunicorn \
  --workers 3 \
  --bind unix:$SITE_DIR/gunicorn.sock \
  $PROJETO.wsgi:application

Restart=always

[Install]
WantedBy=multi-user.target
EOF

sudo chown -R www-data:www-data "$SITE_DIR"
sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE_NAME"
sudo systemctl restart "$SERVICE_NAME"

# ================================
# NGINX + SSL
# ================================
sudo tee "/etc/nginx/sites-available/$DOMINIO" > /dev/null <<EOF
server {
    listen 80;
    server_name $DOMINIO $DOMINIO_WWW;

    location / {
        proxy_pass http://unix:$SITE_DIR/gunicorn.sock;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$remote_addr;
    }
}
EOF

sudo ln -sf "/etc/nginx/sites-available/$DOMINIO" /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx

sudo certbot --nginx -d "$DOMINIO" -d "$DOMINIO_WWW" \
  --non-interactive --agree-tos -m "$EMAIL_CERTBOT"

# ================================
# FINAL
# ================================
echo
echo "✅ Deploy concluído com sucesso!"
echo "🌍 https://$DOMINIO"
echo
echo "Logs:"
echo "sudo journalctl -u $SERVICE_NAME -f"
