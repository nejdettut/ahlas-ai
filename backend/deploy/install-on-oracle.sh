#!/usr/bin/env bash
# Ahlas backend — Oracle Cloud Ubuntu VM deploy script
# Kullanım: VM'e SSH ile bağlan, bu script'i indir/çalıştır:
#   curl -O https://raw.githubusercontent.com/nejdettut/ahlas-ai/master/backend/deploy/install-on-oracle.sh
#   chmod +x install-on-oracle.sh
#   sudo ./install-on-oracle.sh
#
# Bittiğinde:
#   sudo nano /opt/ahlas/backend/.env   # gerçek anahtarları yaz
#   sudo systemctl restart ahlas
#   curl http://localhost:8000/api/v1/health
set -euo pipefail

REPO_URL="https://github.com/nejdettut/ahlas-ai.git"
APP_DIR="/opt/ahlas"
BACKEND_DIR="${APP_DIR}/backend"
ENV_FILE="${BACKEND_DIR}/.env"
SERVICE_NAME="ahlas"

echo "==> 1/7 System update"
apt-get update -y
apt-get upgrade -y

echo "==> 2/7 Base tools + Docker"
apt-get install -y \
    curl ca-certificates gnupg lsb-release git \
    ufw nginx certbot python3-certbot-nginx

# Docker resmi repo
if ! command -v docker >/dev/null 2>&1; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
        https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin
fi

echo "==> 3/7 Clone / update repo"
if [ ! -d "${APP_DIR}/.git" ]; then
    git clone "${REPO_URL}" "${APP_DIR}"
else
    git -C "${APP_DIR}" fetch --all
    git -C "${APP_DIR}" reset --hard origin/master
fi

echo "==> 4/7 .env placeholder"
if [ ! -f "${ENV_FILE}" ]; then
    cp "${BACKEND_DIR}/.env.example" "${ENV_FILE}"
    echo "!! ${ENV_FILE} örnekten oluşturuldu — GERÇEK anahtarları yaz!"
fi
chmod 600 "${ENV_FILE}"

echo "==> 5/7 Docker build + run"
cd "${BACKEND_DIR}"
docker build -t ahlas-backend:latest .
# Eski container'ı temizle
docker rm -f ahlas 2>/dev/null || true
docker run -d \
    --name ahlas \
    --restart unless-stopped \
    --env-file "${ENV_FILE}" \
    -p 127.0.0.1:8000:8000 \
    ahlas-backend:latest

echo "==> 6/7 Nginx reverse proxy (HTTP — HTTPS certbot sonra)"
cat > /etc/nginx/sites-available/ahlas <<'NGINX'
server {
    listen 80;
    server_name _;

    client_max_body_size 25M;

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 180s;
        proxy_send_timeout 180s;
    }
}
NGINX
ln -sf /etc/nginx/sites-available/ahlas /etc/nginx/sites-enabled/ahlas
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl enable nginx
systemctl restart nginx

echo "==> 7/7 Firewall (Ubuntu ufw + Oracle VCN)"
ufw allow OpenSSH
ufw allow 'Nginx Full'   # 80 + 443
ufw --force enable
# Ubuntu 22.04'te iptables kuralları netfilter-persistent ile kalıcı olabilir;
# Oracle Ubuntu image'ları default olarak port 80/443'ü iptables'ta engelliyor:
iptables -I INPUT 6 -m state --state NEW -p tcp --dport 80 -j ACCEPT || true
iptables -I INPUT 6 -m state --state NEW -p tcp --dport 443 -j ACCEPT || true
if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save || true
fi

echo ""
echo "===================================================="
echo "✅ KURULUM TAMAM"
echo "===================================================="
echo ""
echo "1) .env'e gerçek anahtarları yaz:"
echo "     sudo nano ${ENV_FILE}"
echo ""
echo "2) Container'ı yeniden başlat:"
echo "     sudo docker restart ahlas"
echo ""
echo "3) Test:"
echo "     curl http://localhost:8000/api/v1/health"
echo "     curl http://<VM_PUBLIC_IP>/api/v1/health"
echo ""
echo "4) DNS'te ahlas.nejdettut.com A record → <VM_PUBLIC_IP>"
echo ""
echo "5) HTTPS (DNS aktif olduktan sonra):"
echo "     sudo certbot --nginx -d ahlas.nejdettut.com"
echo ""
