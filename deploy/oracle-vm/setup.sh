#!/usr/bin/env bash
set -euo pipefail

# GeoWake Oracle Cloud Free Tier Setup Script
# Run on a fresh Ubuntu 24.04 ARM VM (Ampere A1, 2 OCPU, 12GB RAM)
# Region: Hyderabad (ap-hyderabad-1)
#
# Usage: ssh into your VM, then:
#   curl -sL https://raw.githubusercontent.com/OWNER/REPO/main/deploy/oracle-vm/setup.sh | bash
# OR:
#   scp this file to VM, then: chmod +x setup.sh && ./setup.sh

echo "╔══════════════════════════════════════════════════════════╗"
echo "║   GeoWake Oracle Cloud Free Tier Setup                   ║"
echo "║   Target: Ampere A1 (2 OCPU, 12GB RAM), Ubuntu 24.04     ║"
echo "╚══════════════════════════════════════════════════════════╝"

# ──────────────────────────────────────────────────
# 1. System update + essentials
# ──────────────────────────────────────────────────
echo "▸ Updating system packages..."
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl git jq ufw fail2ban htop

# ──────────────────────────────────────────────────
# 2. Firewall (security hardening)
# ──────────────────────────────────────────────────
echo "▸ Configuring firewall..."
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp comment 'SSH'
sudo ufw allow 80/tcp comment 'HTTP'
sudo ufw allow 443/tcp comment 'HTTPS'
sudo ufw --force enable

# ──────────────────────────────────────────────────
# 3. SSH hardening
# ──────────────────────────────────────────────────
echo "▸ Hardening SSH..."
sudo sed -i 's/#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sudo sed -i 's/#PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo systemctl restart sshd

# ──────────────────────────────────────────────────
# 4. Docker + Docker Compose
# ──────────────────────────────────────────────────
echo "▸ Installing Docker..."
if ! command -v docker &>/dev/null; then
  curl -fsSL https://get.docker.com | sh
  sudo usermod -aG docker "$USER"
  sudo systemctl enable docker
  sudo systemctl start docker
else
  echo "  Docker already installed, skipping."
fi

# Verify Docker
sudo docker --version
sudo docker compose version

# ──────────────────────────────────────────────────
# 5. Create swap (8GB — helps with RAM-constrained graph builds)
# ──────────────────────────────────────────────────
echo "▸ Creating 8GB swap file..."
if ! sudo swapon --show | grep -q swapfile; then
  sudo fallocate -l 8G /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
  echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
  echo 'vm.swappiness=10' | sudo tee -a /etc/sysctl.conf
  sudo sysctl -p
else
  echo "  Swap already exists, skipping."
fi

# ──────────────────────────────────────────────────
# 6. Create application directory
# ──────────────────────────────────────────────────
echo "▸ Creating app directory..."
mkdir -p ~/geowake-deploy
cd ~/geowake-deploy

# ──────────────────────────────────────────────────
# 7. Download India OSM extract for GraphHopper
# ──────────────────────────────────────────────────
echo "▸ Downloading India Southern Zone OSM extract (~530MB)..."
mkdir -p graphhopper_data
if [ ! -f graphhopper_data/india-south-latest.osm.pbf ]; then
  curl -L -o graphhopper_data/india-south-latest.osm.pbf \
    "https://download.geofabrik.de/asia/india-southern-zone-latest.osm.pbf"
else
  echo "  OSM extract already exists, skipping."
fi

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║   SETUP COMPLETE — Next Steps                            ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║                                                          ║"
echo "║  1. Clone the repo:                                      ║"
echo "║     git clone https://github.com/OWNER/REPO ~/WakePoint  ║"
echo "║                                                          ║"
echo "║  2. Copy deployment files:                               ║"
echo "║     cp -r ~/WakePoint/deploy/oracle-vm/* ~/geowake-deploy║"
echo "║                                                          ║"
echo "║  3. Create .env files from .env.example templates:       ║"
echo "║     cp .env.example .env && nano .env                    ║"
echo "║     cp .env.share.example .env.share && nano .env.share  ║"
echo "║     cp .env.n8n.example .env.n8n && nano .env.n8n        ║"
echo "║                                                          ║"
echo "║  4. Edit Caddyfile — replace geowake.example.com with    ║"
echo "║     your actual domain or Oracle VM public IP            ║"
echo "║                                                          ║"
echo "║  5. Start the stack:                                     ║"
echo "║     docker compose up -d                                 ║"
echo "║                                                          ║"
echo "║  6. Pull the Ollama fallback model:                      ║"
echo "║     docker exec -it geowake-ollama-1 ollama pull         ║"
echo "║       qwen3-coder:7b                                     ║"
echo "║                                                          ║"
echo "║  7. Configure Uptime Kuma:                               ║"
echo "║     Visit https://uptime.geowake.example.com             ║"
echo "║     Set up monitors for all endpoints                    ║"
echo "║                                                          ║"
echo "║  8. Configure n8n workflows:                             ║"
echo "║     Visit https://n8n.geowake.example.com                ║"
echo "║     Import workflows from deploy/n8n-workflows/           ║"
echo "║                                                          ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "▸ RAM usage estimate after full deployment:"
echo "  OS + overhead:   ~2GB"
echo "  Caddy:           ~50MB"
echo "  Express API:     ~512MB"
echo "  Share backend:   ~128MB"
echo "  GraphHopper:     ~4GB (Java, -Xmx4g)"
echo "  Uptime Kuma:     ~128MB"
echo "  n8n:             ~1-2GB"
echo "  Ollama (7B Q4):  ~5.5GB (only when model loaded)"
echo "  ─────────────────────"
echo "  WITHOUT Ollama:  ~7-9GB (comfortable)"
echo "  WITH Ollama:     ~12-13GB (tight — load model only when needed)"
echo ""
echo "⚠  If RAM is tight, skip Ollama and use cloud LLM APIs only."
echo "   The model can be pulled and loaded later when needed."
