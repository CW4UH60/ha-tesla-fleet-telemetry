#!/usr/bin/env bash
set -Eeuo pipefail

OPTIONS_FILE=/data/options.json
CERT_DIR=/ssl/tesla-telemetry
NGINX_TEMPLATE=/etc/nginx/templates/tesla-telemetry.conf.template
NGINX_CONFIG=/etc/nginx/nginx.conf

hostname="$(jq -r '.hostname // empty' "${OPTIONS_FILE}")"
proxy_secret="$(jq -r '.proxy_secret // empty' "${OPTIONS_FILE}")"

if [[ ! "${hostname}" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; then
    echo "[fatal] hostname must be a valid public DNS name" >&2
    exit 1
fi
if [[ ! "${proxy_secret}" =~ ^[A-Za-z0-9_-]{32,128}$ ]]; then
    echo "[fatal] proxy_secret must be 32-128 URL-safe characters" >&2
    exit 1
fi
umask 077
mkdir -p "${CERT_DIR}/backups"

certificate_is_current() {
    [[ -s "${CERT_DIR}/ca.crt" \
        && -s "${CERT_DIR}/ca.key" \
        && -s "${CERT_DIR}/server.crt" \
        && -s "${CERT_DIR}/server.key" \
        && -s "${CERT_DIR}/server-fullchain.crt" ]] \
        && openssl x509 -in "${CERT_DIR}/server.crt" -noout -checkhost "${hostname}" >/dev/null 2>&1 \
        && openssl verify -CAfile "${CERT_DIR}/ca.crt" "${CERT_DIR}/server.crt" >/dev/null 2>&1 \
        && openssl x509 -in "${CERT_DIR}/server.crt" -noout -checkend 2592000 >/dev/null 2>&1
}

back_up_existing_certificates() {
    local stamp backup_dir
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    backup_dir="${CERT_DIR}/backups/${stamp}"
    mkdir -p "${backup_dir}"
    for name in ca.crt ca.key ca.srl server.crt server.csr server.key server-fullchain.crt server.ext hostname; do
        if [[ -e "${CERT_DIR}/${name}" ]]; then
            cp -a "${CERT_DIR}/${name}" "${backup_dir}/${name}"
        fi
    done
    echo "[info] backed up the previous receiver certificate set to ${backup_dir}"
}

generate_certificates() {
    echo "[info] generating a private receiver CA and TLS certificate for ${hostname}"
    openssl req -x509 -newkey rsa:3072 -nodes -sha256 -days 3650 \
        -keyout "${CERT_DIR}/ca.key" \
        -out "${CERT_DIR}/ca.crt" \
        -subj "/CN=Home Assistant Tesla Telemetry CA" \
        -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" >/dev/null 2>&1

    openssl req -newkey rsa:2048 -nodes -sha256 \
        -keyout "${CERT_DIR}/server.key" \
        -out "${CERT_DIR}/server.csr" \
        -subj "/CN=${hostname}" >/dev/null 2>&1

    cat >"${CERT_DIR}/server.ext" <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:${hostname}
EOF

    openssl x509 -req -sha256 -days 825 \
        -in "${CERT_DIR}/server.csr" \
        -CA "${CERT_DIR}/ca.crt" \
        -CAkey "${CERT_DIR}/ca.key" \
        -CAcreateserial \
        -extfile "${CERT_DIR}/server.ext" \
        -out "${CERT_DIR}/server.crt" >/dev/null 2>&1

    cat "${CERT_DIR}/server.crt" "${CERT_DIR}/ca.crt" >"${CERT_DIR}/server-fullchain.crt"
    printf '%s\n' "${hostname}" >"${CERT_DIR}/hostname"
    chmod 0600 "${CERT_DIR}/ca.key" "${CERT_DIR}/server.key"
    chmod 0644 "${CERT_DIR}/ca.crt" "${CERT_DIR}/server.crt" "${CERT_DIR}/server-fullchain.crt"
    rm -f "${CERT_DIR}/server.csr" "${CERT_DIR}/server.ext" "${CERT_DIR}/ca.srl"
}

if certificate_is_current; then
    echo "[info] reusing the existing receiver certificate for ${hostname}"
else
    if compgen -G "${CERT_DIR}/*" >/dev/null; then
        back_up_existing_certificates
    fi
    generate_certificates
fi

sed \
    -e "s|__HOSTNAME__|${hostname}|g" \
    -e "s|__PROXY_SECRET__|${proxy_secret}|g" \
    "${NGINX_TEMPLATE}" >"${NGINX_CONFIG}"
chmod 0600 "${NGINX_CONFIG}"

nginx -t
echo "[info] receiver ready on TCP 4443; forwarding verified vehicle streams to Home Assistant"
exec nginx -g 'daemon off;'
