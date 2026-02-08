#!/bin/bash
set -euo pipefail

# ================================
# VERIFICA PYTHON3, PIP E VENV
# ================================
echo "Verificando Python3, pip e venv..."

# Atualiza repositórios
sudo apt update

# Instala Python3, pip e venv
sudo apt install -y python3 python3-pip python3-venv python3-setuptools

# Se pip ainda não estiver disponível, força instalação com ensurepip
if ! python3 -m pip --version >/dev/null 2>&1; then
    echo "pip não encontrado, instalando via ensurepip..."
    python3 -m ensurepip --upgrade
fi

# Verifica se venv funciona criando um teste rápido
TEMP_TEST_VENV="./venv_test_check"
if ! python3 -m venv "$TEMP_TEST_VENV" >/dev/null 2>&1; then
    echo "Erro: venv ainda não funciona. Certifique-se de que python3-venv está corretamente instalado."
    exit 1
fi
rm -rf "$TEMP_TEST_VENV"

echo "Python3, pip e venv disponíveis."

# ================================
# REMOVE VENV TEMPORÁRIO ANTIGO
# ================================
TEMP_VENV="./venv_temp"
if [ -d "$TEMP_VENV" ]; then
    echo "Removendo venv temporário antigo..."
    rm -rf "$TEMP_VENV"
fi

# ================================
# CRIA VENV TEMPORÁRIO LIMPO
# ================================
echo "Criando venv temporário..."
python3 -m venv "$TEMP_VENV"
PIP_TEMP="$TEMP_VENV/bin/pip"
PYTHON_TEMP="$TEMP_VENV/bin/python"

# ================================
# INSTALA DJANGO NO VENV TEMPORÁRIO
# ================================
"$PIP_TEMP" install --upgrade pip
"$PIP_TEMP" install django

# ================================
# CRIA .ENV INTERATIVO SE NÃO EXISTIR
# ================================
if [ ! -f ".env" ]; then
    echo "Criando .env interativo..."

    while true; do
        read -rp "Nome do site (NOME_SITE): " NOME_SITE
        read -rp "Domínio principal (DOMINIO): " DOMINIO
        DOMINIO_WWW="www.$DOMINIO"
        echo "Domínio www definido automaticamente como: $DOMINIO_WWW"
        read -rp "E-mail para Certbot (EMAIL_CERTBOT): " EMAIL_CERTBOT

        echo
        echo "==== Resumo das variáveis inseridas ===="
        echo "Nome do site      : $NOME_SITE"
        echo "Domínio principal : $DOMINIO"
        echo "Domínio www       : $DOMINIO_WWW"
        echo "E-mail Certbot    : $EMAIL_CERTBOT"
        echo "======================================="
        echo

        read -rp "Está correto? (s/n): " CONFIRMA
        if [[ "$CONFIRMA" =~ ^[Ss]$ ]]; then
            break
        else
            echo "Vamos corrigir os valores..."
            echo
        fi
    done

    PROJETO="core"
    APP="principal"
    SERVICE_NAME="$NOME_SITE"
    DB_NAME="${NOME_SITE}_db"
    DB_USER="usr_${NOME_SITE}"
    DB_PASS=$(openssl rand -base64 16)
    MYSQL_ROOT_USER="root"
    MYSQL_ROOT_PASS=$(openssl rand -base64 16)

    # Gera SECRET_KEY do Django usando venv temporário
    SECRET_KEY_DJANGO=$("$PYTHON_TEMP" -c "from django.core.management.utils import get_random_secret_key; print(get_random_secret_key())")

    cat > .env <<EOF
# Variáveis obrigatórias
NOME_SITE=$NOME_SITE
DOMINIO=$DOMINIO
DOMINIO_WWW=$DOMINIO_WWW
EMAIL_CERTBOT=$EMAIL_CERTBOT

# Projeto Django
PROJETO=$PROJETO
APP=$APP
SERVICE_NAME=$SERVICE_NAME

# Banco MySQL
DB_NAME=$DB_NAME
DB_USER=$DB_USER
DB_PASS=$DB_PASS

# Usuário root do MySQL
MYSQL_ROOT_USER=$MYSQL_ROOT_USER
MYSQL_ROOT_PASS=$MYSQL_ROOT_PASS

# Chave secreta Django
SECRET_KEY_DJANGO=$SECRET_KEY_DJANGO
EOF

    echo ".env criado com sucesso!"
fi

# ================================
# REMOVE VENV TEMPORÁRIO
# ================================
rm -rf "$TEMP_VENV"

# ================================
# CARREGA VARIÁVEIS DO .ENV
# ================================
export $(grep -v '^#' .env | xargs)

# ================================
# PATHS E DIRETÓRIOS
# ================================
SITE_DIR="/var/www/$NOME_SITE"
CONFIG_PATH="/etc/config_${NOME_SITE}"
CONFIG_FILE="${CONFIG_PATH}/${NOME_SITE}.config"
LOG_PATH="/var/log/${NOME_SITE}"
NGINX_CONF="/etc/nginx/sites-available/${DOMINIO}"

# ================================
# CRIA BANCO DE DADOS E USUÁRIO MYSQL
# ================================
echo "Verificando MySQL..."

# Instala MySQL se não existir
if ! command -v mysql >/dev/null 2>&1; then
    echo "MySQL não encontrado. Instalando MySQL server e client..."
    sudo apt update
    sudo apt install -y mysql-server mysql-client
    sudo systemctl start mysql
    sudo systemctl enable mysql
fi

# Cria banco e usuário usando sudo
echo "Criando banco e usuário MySQL..."
sudo mysql <<EOF
CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF

echo "Banco de dados '$DB_NAME' e usuário '$DB_USER' configurados."

# ================================
# CRIA DIRETÓRIO DO PROJETO
# ================================
sudo mkdir -p "$SITE_DIR"
sudo chown $USER:$USER "$SITE_DIR"  # garante permissão para criar venv
cd "$SITE_DIR"

# ================================
# AMBIENTE VIRTUAL
# ================================
if [ ! -d "venv_${NOME_SITE}" ]; then
    python3 -m venv "venv_${NOME_SITE}"
fi
PIP="$SITE_DIR/venv_${NOME_SITE}/bin/pip"
PYTHON="$SITE_DIR/venv_${NOME_SITE}/bin/python"
DJANGO_ADMIN="$SITE_DIR/venv_${NOME_SITE}/bin/django-admin"

# ================================
# INSTALA DEPENDÊNCIAS
# ================================
"$PIP" install --upgrade pip
"$PIP" install django mysqlclient gunicorn python-dotenv

# ================================
# CRIA PROJETO DJANGO SE NÃO EXISTIR
# ================================
if [ ! -d "$SITE_DIR/$PROJETO" ]; then
    "$DJANGO_ADMIN" startproject "$PROJETO" .
fi

SETTINGS="$SITE_DIR/$PROJETO/settings.py"

# ================================
# CONFIGURAÇÕES DJANGO
# ================================
sed -i "s/^DEBUG = True/DEBUG = False/" "$SETTINGS"
sed -i "/^ALLOWED_HOSTS/d" "$SETTINGS"
echo "ALLOWED_HOSTS = ['$DOMINIO', '$DOMINIO_WWW']" >> "$SETTINGS"

# ================================
# CONFIGURA ARQUIVO DE CONFIGURAÇÃO SECRETA
# ================================
sudo mkdir -p "$CONFIG_PATH"
sudo chown root:www-data "$CONFIG_PATH"
sudo chmod 750 "$CONFIG_PATH"

sudo tee "$CONFIG_FILE" > /dev/null <<EOF
[database]
name=$DB_NAME
user=$DB_USER
password=$DB_PASS

[django]
secret_key=$SECRET_KEY_DJANGO
EOF

sudo chmod 640 "$CONFIG_FILE"
sudo chown root:www-data "$CONFIG_FILE"

# ================================
# AJUSTA settings.py PARA USAR CONFIG
# ================================
sed -i "/SECRET_KEY =/d" "$SETTINGS"
cat <<EOL >> "$SETTINGS"

import configparser
import os

config = configparser.ConfigParser(interpolation=None)
config.read('$CONFIG_FILE')

SECRET_KEY = config['django']['secret_key']

DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.mysql',
        'NAME': config['database']['name'],
        'USER': config['database']['user'],
        'PASSWORD': config['database']['password'],
        'HOST': 'localhost',
        'PORT': '3306',
    }
}

STATIC_ROOT = os.path.join(BASE_DIR, 'staticfiles')

LOGGING = {
    'version': 1,
    'disable_existing_loggers': False,
    'formatters': {
        'verbose': {'format': '{levelname} {asctime} {module} {message}', 'style': '{'},
    },
    'handlers': {
        'file': {'level': 'ERROR', 'class': 'logging.FileHandler', 'filename': '$LOG_PATH/error.log', 'formatter': 'verbose'},
        'app_debug': {'level': 'DEBUG', 'class': 'logging.FileHandler', 'filename': '$LOG_PATH/app_debug.log', 'formatter': 'verbose'},
    },
    'loggers': {
        'django': {'handlers': ['file'], 'level': 'ERROR', 'propagate': True},
        'app': {'handlers': ['app_debug'], 'level': 'DEBUG', 'propagate': False},
    },
}
EOL

# ================================
# CRIA STATIC E LOGS
# ================================
mkdir -p "$SITE_DIR/staticfiles"
sudo mkdir -p "$LOG_PATH"
sudo touch "$LOG_PATH/error.log" "$LOG_PATH/app_debug.log"
sudo chown www-data:www-data "$LOG_PATH"/*.log
sudo chmod 640 "$LOG_PATH"/*.log

# ================================
# CONFIGURAÇÃO TEMPORÁRIA NGINX
# ================================
sudo tee "$NGINX_CONF" > /dev/null <<EOF
server {
    listen 80;
    server_name $DOMINIO $DOMINIO_WWW;

    location / {
        proxy_pass http://unix:$SITE_DIR/gunicorn.sock;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

sudo ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl reload nginx

# ================================
# EMISSÃO IDÊNTICA DE CERTIFICADO SSL COM CERTBOT
# ================================
CERT_PATH="/etc/letsencrypt/live/$DOMINIO/fullchain.pem"

if [ -f "$CERT_PATH" ]; then
    echo "Certificado SSL para $DOMINIO já existe. Pulando emissão."
else
    echo "Emitindo certificado SSL para $DOMINIO e $DOMINIO_WWW..."
    if sudo certbot --nginx -d "$DOMINIO" -d "$DOMINIO_WWW" \
        --non-interactive --agree-tos -m "$EMAIL_CERTBOT"; then
        echo "Certificado emitido com sucesso."
    else
        echo "Falha na emissão do certificado. Verifique DNS, porta 80 aberta ou limite da Let's Encrypt."
    fi
fi

# ================================
# CONFIGURAÇÃO DEFINITIVA DO NGINX COM SSL
# ================================
sudo tee "$NGINX_CONF" > /dev/null <<EOF
server {
    listen 80;
    server_name $DOMINIO $DOMINIO_WWW;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name $DOMINIO $DOMINIO_WWW;

    client_max_body_size 3M;

    location /static/ { alias $SITE_DIR/staticfiles/; }
    location /media/ { alias $SITE_DIR/media/; }

    location / {
        proxy_pass http://unix:$SITE_DIR/gunicorn.sock;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    ssl_certificate /etc/letsencrypt/live/$DOMINIO/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMINIO/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
}
EOF

sudo nginx -t && sudo systemctl reload nginx

# ================================
# GUNICORN SERVICE
# ================================
sudo chown -R www-data:www-data "$SITE_DIR"
sudo chmod 755 "$SITE_DIR"

sudo tee "/etc/systemd/system/${SERVICE_NAME}.service" > /dev/null <<EOF
[Unit]
Description=gunicorn daemon for $DOMINIO
After=network.target

[Service]
User=www-data
Group=www-data
WorkingDirectory=$SITE_DIR
ExecStart=$SITE_DIR/venv_${NOME_SITE}/bin/gunicorn --access-logfile - --workers 3 --bind unix:$SITE_DIR/gunicorn.sock --umask 007 $PROJETO.wsgi:application
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE_NAME"
sudo systemctl start "$SERVICE_NAME"

# ================================
# CRIAÇÃO DO APP
# ================================
cd "$SITE_DIR"
if [ ! -d "$SITE_DIR/$APP" ]; then
    "$PYTHON" manage.py startapp "$APP"
fi

mkdir -p "$SITE_DIR/$APP/templates/$APP"
mkdir -p "$SITE_DIR/$APP/static/$APP/css" "$SITE_DIR/$APP/static/$APP/js" "$SITE_DIR/$APP/static/$APP/images" "$SITE_DIR/$APP/static/$APP/videos"

# ================================
# CONFIGURA APP - TEMPLATES E STATIC
# ================================
APP_DIR="$SITE_DIR/$APP"

# Cria diretórios de templates e static
mkdir -p "$APP_DIR/templates/$APP"
mkdir -p "$APP_DIR/static/$APP/css" "$APP_DIR/static/$APP/js" "$APP_DIR/static/$APP/images" "$APP_DIR/static/$APP/videos"

# Cria template HTML inicial
tee "$APP_DIR/templates/$APP/home.html" > /dev/null <<EOF
<!DOCTYPE html>
<html lang="pt-BR">
<head>
    <meta charset="UTF-8" />
    <title>Página Inicial</title>
    {% load static %}
    <link rel="stylesheet" href="{% static '$APP/css/home.css' %}">
</head>
<body>
    <h1 class="typewriter-line line1">Bem-vindo ao meu site!</h1>
    <h2 class="typewriter-line line2">Estamos construindo algo incrível...</h2>
</body>
</html>
EOF

# Cria CSS com animação inicial
tee "$APP_DIR/static/$APP/css/home.css" > /dev/null <<EOF
* { margin: 0; padding: 0; box-sizing: border-box; }
body {
  height: 100vh; display: flex; flex-direction: column; justify-content: center; align-items: center;
  padding: 2rem;
  background: linear-gradient(-45deg, #2e3a59, #1e2a38, #3c4b64, #1c2c40);
  background-size: 400% 400%;
  animation: gradientMove 15s ease infinite;
  font-family: "Courier New", monospace; color: #ffffff;
}
.typewriter-line { overflow: hidden; border-right: 2px solid #ffffff; white-space: nowrap; width: 0; font-size: clamp(1rem, 4vw, 2rem);}
.line1 { animation: typing1 3s steps(30,end) forwards, blink 0.8s step-end infinite; }
.line2 { animation: typing2 2s steps(20,end) forwards, blink 0.8s step-end infinite; animation-delay: 3.5s; }
@keyframes gradientMove {0%{background-position:0%50%;}50%{background-position:100%50%;}100%{background-position:0%50%;}}
@keyframes typing1 {from {width:0;} to {width:100%;}}
@keyframes typing2 {from {width:0;} to {width:100%;}}
@keyframes blink {from,to{border-color:transparent;}50%{border-color:#ffffff;}}
@media(max-width:400px){body{padding:1rem;} .typewriter-line{font-size:1.1rem;}}
EOF

# Cria JS inicial vazio
touch "$APP_DIR/static/$APP/js/home.js"

# ================================
# ADICIONA APP NO INSTALLED_APPS
# ================================
if ! grep -q "'$APP'" "$SETTINGS"; then
    sed -i "/INSTALLED_APPS = \[/a\    '$APP'," "$SETTINGS"
fi

# ================================
# CONFIGURA URLs DO APP
# ================================
URLS_FILE="$SITE_DIR/$PROJETO/urls.py"

# Garante que 'include' esteja importado
if grep -q "^from django.urls import path" "$URLS_FILE" && ! grep -q "include" "$URLS_FILE"; then
    sed -i "s/^from django.urls import path/from django.urls import path, include/" "$URLS_FILE"
fi
if ! grep -q "^from django.urls import " "$URLS_FILE"; then
    sed -i "1ifrom django.urls import path, include" "$URLS_FILE"
fi

# Adiciona path do app se não estiver presente
if ! grep -q "include('$APP.urls')" "$URLS_FILE"; then
    sed -i "/urlpatterns = \[/a\    path('', include('$APP.urls'))," "$URLS_FILE"
fi

# ================================
# CRIA ARQUIVOS DE URL E VIEWS DO APP
# ================================
# URLs
tee "$APP_DIR/urls.py" > /dev/null <<EOF
from django.urls import path
from . import views

urlpatterns = [
    path('', views.home, name='home'),
]
EOF

# Views
tee "$APP_DIR/views.py" > /dev/null <<EOF
from django.shortcuts import render

def home(request):
    return render(request, '$APP/home.html')
EOF

# ================================
# COLETA ESTÁTICOS
# ================================
"$PYTHON" manage.py collectstatic --noinput
sudo systemctl restart "$SERVICE_NAME"

echo -e "\nInstalação do site '$NOME_SITE' concluída com sucesso em $DOMINIO"
sudo journalctl -u "${SERVICE_NAME}.service" -n 20 --no-pager
