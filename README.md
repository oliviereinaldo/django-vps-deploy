# ================================
# Django VPS Deploy
# ================================

Automação para provisionamento e deploy de aplicação Django em ambiente VPS Linux, com foco em segurança básica, padronização e repetibilidade.

# ================================
# Visão Geral
# ================================

Este repositório contém:

- Procedimento de hardening inicial da VPS
- Script automatizado de deploy para aplicação Django
- Estrutura mínima para execução segura em ambiente de produção

O fluxo foi organizado para reduzir a superfície de ataque antes da publicação da aplicação.

# ================================
# Pré-requisitos
# ================================

- VPS com Ubuntu Server
- Acesso inicial via SSH
- Windows 10/11 com OpenSSH (ou ambiente compatível)
- Git instalado localmente

# ================================
# Ordem de Execução
# ================================

A sequência abaixo deve ser respeitada.

### 1. Configuração e Hardening da VPS

Antes de qualquer deploy, execute integralmente as instruções do arquivo:

config_vps.txt:

Este procedimento contempla:

- Configuração de autenticação SSH por chave
- Bloqueio de login root
- Desativação de autenticação por senha
- Configuração de firewall (UFW)

Somente após a validação do acesso seguro deve-se prosseguir.

### 2. Deploy da Aplicação

Após concluir a configuração da VPS:

```bash
git clone https://github.com/oliviereinaldo/django-vps-deploy.git
cd django-vps-deploy
chmod +x deploy_site.sh
./deploy_site.sh
```

O script realiza a configuração automatizada do ambiente para execução da aplicação Django

# ================================
# Estrutura do Repositório
# ================================

django-vps-deploy/
│
├── config_vps.txt # Procedimento de configuração e hardening
├── deploy_site.sh # Script automatizado de deploy
├── LICENSE # Licença do projeto
├── README.md # Documentação principal
└── DISCLAIMER.md # Termos de responsabilidade
