#!/usr/bin/env bash
# Instala o virtual host do FreeLLMAPI no nginx do host.
# Uso: sudo ./scripts/install-nginx.sh [dominio]
set -euo pipefail

DOMAIN="${1:-freellmapi.essentjus.com.br}"
EMAIL="${CERTBOT_EMAIL:-pedro.fausto@essentjus.com.br}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT=3001

if [[ $EUID -ne 0 ]]; then
  echo "Execute com sudo: sudo ./scripts/install-nginx.sh ${DOMAIN}"
  exit 1
fi

if [[ -f "${ROOT}/.env" ]]; then
  env_port="$(grep -E '^PORT=' "${ROOT}/.env" | tail -1 | cut -d= -f2- | tr -d "\"'" | tr -d '[:space:]' || true)"
  if [[ -n "${env_port}" ]]; then
    PORT="${env_port}"
  fi
fi

if ! command -v nginx >/dev/null 2>&1 || ! command -v certbot >/dev/null 2>&1; then
  apt-get update
  apt-get install -y nginx certbot
fi

mkdir -p /var/www/certbot /etc/letsencrypt

cp "${ROOT}/nginx/conf.d/00-upgrade-map.conf" /etc/nginx/conf.d/00-upgrade-map.conf
cp "${ROOT}/nginx/ssl/options-ssl-nginx.conf" /etc/letsencrypt/options-ssl-nginx.conf
if [[ ! -f /etc/letsencrypt/ssl-dhparams.pem ]]; then
  openssl dhparam -out /etc/letsencrypt/ssl-dhparams.pem 2048
fi

install_proxy_conf() {
  local dest="$1"
  sed \
    -e "s/freellmapi.essentjus.com.br/${DOMAIN}/g" \
    -e "s/127.0.0.1:3001/127.0.0.1:${PORT}/g" \
    "${ROOT}/nginx/freellmapi.conf" > "${dest}"
}

# HTTP com proxy e desafio ACME. O app responde mesmo antes do certificado.
cat > "/etc/nginx/sites-available/${DOMAIN}" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    client_max_body_size 32m;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        proxy_pass http://127.0.0.1:${PORT};
        proxy_http_version 1.1;

        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade           \$http_upgrade;
        proxy_set_header Connection        \$connection_upgrade;

        proxy_buffering         off;
        proxy_request_buffering off;
        add_header X-Accel-Buffering "no" always;

        proxy_read_timeout  3600s;
        proxy_send_timeout  3600s;
    }
}
EOF

ln -sf "/etc/nginx/sites-available/${DOMAIN}" "/etc/nginx/sites-enabled/${DOMAIN}"
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl enable nginx
systemctl reload nginx

CERT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
if [[ ! -f "${CERT}" ]]; then
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
    if [[ ! -e /var/lib/letsencrypt/.certbot.lock ]]; then
      break
    fi
    echo "Outro Certbot está em execução (em geral o timer de renovação). Aguardando..."
    sleep 10
  done
  if [[ -e /var/lib/letsencrypt/.certbot.lock ]]; then
    echo "O Certbot continua ocupado. Rode o setup de novo daqui a um minuto."
    exit 1
  fi

  certbot_log="$(mktemp)"
  if ! certbot certonly --webroot -w /var/www/certbot \
    -d "${DOMAIN}" --non-interactive --agree-tos --keep-until-expiring -m "${EMAIL}" \
    >"${certbot_log}" 2>&1; then
    echo ""
    echo "Nginx em HTTP está no ar: http://${DOMAIN} → 127.0.0.1:${PORT}"
    echo "O certificado não saiu:"
    grep -E "Detail:|Another instance|DNS problem|Hint:" "${certbot_log}" || tail -n 20 "${certbot_log}"
    if grep -q "NXDOMAIN" "${certbot_log}"; then
      echo "Não existe registro DNS para ${DOMAIN}. Crie o A para o IP público desta EC2 e rode o setup de novo."
    elif grep -q "failed to download\|Some challenges have failed" "${certbot_log}"; then
      echo "O nome precisa resolver nesta EC2 com a nuvem da Cloudflare cinza durante a emissão."
      echo "Com a nuvem laranja o desafio HTTP não chega aqui. Depois do certificado, a nuvem laranja pode voltar."
    fi
    rm -f "${certbot_log}"
    exit 1
  fi
  rm -f "${certbot_log}"
fi

install_proxy_conf "/etc/nginx/sites-available/${DOMAIN}"
nginx -t
systemctl reload nginx

echo ""
echo "Nginx ativo: https://${DOMAIN} → http://127.0.0.1:${PORT}"
