#!/bin/bash

# ───────────── Escolher diretório do projeto ─────────────
read -p "Digite o caminho do diretório do projeto onde será iniciado o Git: " PROJECT_DIR

# Verifica se o diretório existe
if [ ! -d "$PROJECT_DIR" ]; then
    echo "Diretório não encontrado. Abortando o processo."
    exit 1
fi

# Entrar no diretório do projeto
cd "$PROJECT_DIR" || { echo "Não foi possível entrar no diretório."; exit 1; }
echo "Diretório do projeto definido como: $(pwd)"

read -p "Confirma que deseja iniciar o versionamento neste diretório? (s/n): " CONFIRM
if [[ "$CONFIRM" != "s" && "$CONFIRM" != "S" ]]; then
    echo "Processo cancelado pelo usuário."
    exit 1
fi

# ───────────── Verifica Git ─────────────
if ! command -v git &> /dev/null; then
    echo "Git não encontrado. Instalando automaticamente..."
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        sudo apt update && sudo apt install git -y
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        if ! command -v brew &> /dev/null; then
            echo "Homebrew não encontrado. Instale o Homebrew primeiro: https://brew.sh/"
            exit 1
        fi
        brew install git
    else
        echo "Sistema não suportado para instalação automática. Instale o Git manualmente."
        exit 1
    fi
fi
echo "Git encontrado: $(git --version)"

# ───────────── Gerar chave SSH personalizada ─────────────
read -p "Digite um nome para a chave SSH (ex: id_ed25519_meuprojeto): " SSH_NAME
SSH_KEY="$HOME/.ssh/$SSH_NAME"

if [ ! -f "$SSH_KEY" ]; then
    read -p "Digite seu email para a chave SSH: " user_email
    ssh-keygen -t ed25519 -C "$user_email" -f "$SSH_KEY" -N ""
else
    echo "Chave SSH já existe: $SSH_KEY"
fi

eval "$(ssh-agent -s)"
ssh-add "$SSH_KEY"

echo "----------------------------"
echo "Copie esta chave e registre no GitHub:"
echo "Página para registro de chaves SSH:"
echo "https://github.com/settings/keys"
echo ""
cat "${SSH_KEY}.pub"
echo "----------------------------"
read -p "Pressione Enter após registrar a chave SSH no repositório remoto..."

echo "Testando conexão SSH..."
ssh -T git@github.com || echo "Conexão SSH falhou ou aguardando registro."

# ───────────── Inicializar repositório ─────────────
git init
echo "Repositório Git inicializado."

# ───────────── Configurar Git local caso não registrado ─────────────
if ! git config --list | grep user.name &> /dev/null; then
    read -p "Digite seu nome para o Git: " git_user
    git config --global user.name "$git_user"
fi

if ! git config --list | grep user.email &> /dev/null; then
    read -p "Digite seu email para o Git: " git_email
    git config --global user.email "$git_email"
fi
echo "Configuração Git atual:"
git config --list

# ───────────── Criar .gitignore ─────────────
cat <<EOL > .gitignore
# Virtual environment
venv/
.env/

# Python cache
__pycache__/
*.py[cod]

# IDEs
.vscode/
.idea/

# Arquivos temporários
*.log
*.sqlite3
EOL
echo ".gitignore criado."

# ───────────── Detectar venv e criar requirements.txt ─────────────
if [ -d "venv" ]; then
    echo "Virtual environment detectado em ./venv. Gerando requirements.txt..."
    source venv/bin/activate 2>/dev/null || source venv/Scripts/activate 2>/dev/null
    pip freeze > requirements.txt
    echo "requirements.txt gerado automaticamente a partir do venv."
else
    echo "Nenhum venv detectado. Pulando geração de requirements.txt."
fi

# ───────────── Adicionar arquivos e commit ─────────────
git add .
git commit -m "Primeiro commit: inicialização do projeto"
echo "Commit inicial realizado."

# ───────────── Configurar repositório remoto via SSH ─────────────
read -p "Digite a URL SSH do repositório remoto (ex: git@github.com:usuario/repositorio.git): " remote_url

# Mostrar para o usuário confirmar
echo "Você informou a URL do repositório remoto como: $remote_url"
read -p "Confirma que deseja usar esta URL para configurar o remoto? (s/n): " CONFIRM_REMOTE
if [[ "$CONFIRM_REMOTE" != "s" && "$CONFIRM_REMOTE" != "S" ]]; then
    echo "Processo cancelado pelo usuário."
    exit 1
fi

# Adicionar ou atualizar remoto
if git remote | grep origin &> /dev/null; then
    git remote set-url origin "$remote_url"
else
    git remote add origin "$remote_url"
fi
echo "Repositório remoto configurado com sucesso."

# ───────────── Push inicial ─────────────
git branch -M main
git push -u origin main || git push -u origin HEAD
echo "Projeto enviado para o repositório remoto com sucesso!"
