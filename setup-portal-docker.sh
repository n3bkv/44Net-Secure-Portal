#!/usr/bin/env bash
set -euo pipefail

# setup-portal-docker.sh
# Traefik (ACME prod) + Authelia forward auth protecting LAN server (ex. Node-RED)
# - ACME HTTP-01 (production only)
# - HTTP(80): redirect via middleware; routers use service noop@internal
# - HTTPS: one SAN cert for portal+auth issued by authelia router; portal reuses
# - Writes .env with TZ for Compose
# - Optional wipe of /opt/portal-docker before rebuild

BASE="/opt/portal-docker"
TRAEFIK_DIR="$BASE/traefik"
AUTHELIA_DIR="$BASE/authelia"
LE_DIR="$TRAEFIK_DIR/letsencrypt"

NETWORK_NAME="portal_proxy"
COMPOSE_FILE="$BASE/docker-compose.yml"
TRAEFIK_STATIC="$TRAEFIK_DIR/traefik.yml"
TRAEFIK_DYNAMIC="$TRAEFIK_DIR/dynamic.yml"
ACME_FILE="$LE_DIR/acme.json"
ENV_FILE="$BASE/.env"

green(){ printf '\e[32m%s\e[0m\n' "$*"; }
red(){ printf '\e[31m%s\e[0m\n' "$*"; }
note(){ printf -- "--> %s\n" "$*"; }
die(){ red "ERROR: $*"; exit 1; }

require_root(){ [[ $EUID -eq 0 ]] || die "Run as root (sudo)."; }
is_cmd(){ command -v "$1" >/dev/null 2>&1; }

validate_domain(){ local d="${1:?}"; [[ "$d" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] || die "Invalid domain: $d"; }
validate_url(){ local u="${1:?}"; [[ "$u" =~ ^https?://[A-Za-z0-9\.\-:]+(/.*)?$ ]] || die "Invalid URL: $u"; }
calc_base_zone(){ local host="${1:?}"; printf '%s\n' "${host#*.}"; }

hash_password_bcrypt(){
  local pw="${1:?}"
  docker pull -q authelia/authelia:latest >/dev/null
  local out hash
  out="$(docker run --rm authelia/authelia:latest authelia crypto hash generate bcrypt --password "$pw" --no-confirm || true)"
  hash="$(printf '%s\n' "$out" | awk '/^\$2/{print $0} /^Digest:/{print $2}' | tail -n1 | tr -d '\r')"
  [[ -n "$hash" ]] || die "Failed to generate bcrypt hash"
  printf '%s' "$hash"
}

docker_network_exists(){ docker network ls --format '{{.Name}}' | grep -qx "$NETWORK_NAME"; }
docker_network_is_compose_owned(){
  local id label
  id="$(docker network inspect -f '{{.Id}}' "$NETWORK_NAME" 2>/dev/null || true)"
  [[ -z "$id" ]] && return 1
  label="$(docker network inspect -f '{{index .Labels "com.docker.compose.network"}}' "$NETWORK_NAME" 2>/dev/null || true)"
  [[ "$label" == "$NETWORK_NAME" ]]
}

ensure_docker(){
  is_cmd docker || { note "Installing Docker…"; curl -fsSL https://get.docker.com | sh; }
  docker compose version >/dev/null 2>&1 || die "Docker Compose plugin missing"
}

prompt_inputs(){
  echo
  echo "This sets up Traefik + Authelia to an internal LAN server (ex. Node-RED) behind an SSO portal."
  echo

  read -rp "Portal domain (e.g., portal.example.com): " PORTAL_DOMAIN
  validate_domain "$PORTAL_DOMAIN"

  local base_zone; base_zone="$(calc_base_zone "$PORTAL_DOMAIN")"
  read -rp "Auth domain [auth.${base_zone}]: " AUTH_DOMAIN
  AUTH_DOMAIN="${AUTH_DOMAIN:-auth.${base_zone}}"
  validate_domain "$AUTH_DOMAIN"

  read -rp "Let's Encrypt contact email: " LE_EMAIL
  [[ -n "$LE_EMAIL" ]] || die "Email required"

  read -rp "Internal server URL/Port URL (e.g., http://192.168.1.100:1880): " NODERED_URL
  validate_url "$NODERED_URL"

  read -rp "Timezone [America/Los_Angeles]: " TZ
  TZ="${TZ:-America/Los_Angeles}"

  read -rp "Authelia username [admin]: " AUTH_USER
  AUTH_USER="${AUTH_USER:-admin}"
  read -rsp "Authelia password (hashed into users DB): " AUTH_PASS; echo
  read -rp "Authelia email for user: " AUTH_EMAIL

  read -rp "Wipe existing $BASE and containers first? [y/N]: " NUKE
  NUKE="${NUKE:-N}"

  read -rp "Enable Authelia login lockout control (regulation)? [Y/n]: " ENABLE_REGULATION
  ENABLE_REGULATION="${ENABLE_REGULATION:-Y}"

  if [[ "${ENABLE_REGULATION,,}" == "y" ]]; then
    read -rp "Max retries before lockout [5]: " REG_MAX_RETRIES
    REG_MAX_RETRIES="${REG_MAX_RETRIES:-5}"
    read -rp "Find time window (e.g., 2m, 10m, 1h, 6h) [10m]: " REG_FIND_TIME
    REG_FIND_TIME="${REG_FIND_TIME:-10m}"
    read -rp "Ban time duration (e.g., 5m, 1h, 1d, 1w) [1h]: " REG_BAN_TIME
    REG_BAN_TIME="${REG_BAN_TIME:-1h}"
  else
    REG_MAX_RETRIES=""
    REG_FIND_TIME=""
    REG_BAN_TIME=""
  fi

  echo
  echo "== Summary =="
  echo "Portal:   $PORTAL_DOMAIN"
  echo "Auth:     $AUTH_DOMAIN"
  echo "LE email: $LE_EMAIL"
  echo "Backend:  $NODERED_URL"
  echo "User:     $AUTH_USER <$AUTH_EMAIL>"
  echo "TZ:       $TZ"
  if [[ "${ENABLE_REGULATION,,}" == "y" ]]; then
    echo "Lockout:  enabled (max_retries=$REG_MAX_RETRIES, find_time=$REG_FIND_TIME, ban_time=$REG_BAN_TIME)"
  else
    echo "Lockout:  disabled"
  fi
  echo
  read -rp "Proceed? [y/N]: " OKGO
  [[ "${OKGO:-N}" == "y" ]] || die "Aborted."
}

write_compose(){
  local network_block
  if docker_network_exists && ! docker_network_is_compose_owned; then
    network_block="$(cat <<NET
networks:
  ${NETWORK_NAME}:
    external: true
NET
)"
  else
    network_block="$(cat <<NET
networks:
  ${NETWORK_NAME}:
    name: ${NETWORK_NAME}
NET
)"
  fi

  cat >"$COMPOSE_FILE" <<YAML
services:
  traefik:
    image: traefik:v2.11
    command:
      - "--providers.file.directory=/etc/traefik/dynamic"
      - "--providers.file.watch=true"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.websecure.address=:443"
    ports:
      - "80:80"
      - "443:443"
    networks: [ ${NETWORK_NAME} ]
    volumes:
      - ./traefik/traefik.yml:/etc/traefik/traefik.yml:ro
      - ./traefik/dynamic.yml:/etc/traefik/dynamic/dynamic.yml:ro
      - ./traefik/letsencrypt:/letsencrypt
    restart: unless-stopped

  authelia:
    image: authelia/authelia:latest
    networks: [ ${NETWORK_NAME} ]
    environment:
      - TZ=\${TZ}
    volumes:
      - ./authelia:/config
    restart: unless-stopped

${network_block}
YAML
}

write_traefik_static(){
  cat >"$TRAEFIK_STATIC" <<'YAML'
api:
  dashboard: false

providers:
  file:
    directory: /etc/traefik/dynamic
    watch: true

entryPoints:
  web:
    address: ":80"
  websecure:
    address: ":443"

certificatesResolvers:
  le:
    acme:
      email: "${LE_EMAIL}"
      storage: "/letsencrypt/acme.json"
      keyType: "RSA4096"
      certificatesDuration: 2160
      httpChallenge:
        entryPoint: web

log:
  level: INFO
YAML
}

write_traefik_dynamic(){
  cat >"$TRAEFIK_DYNAMIC" <<YAML
http:
  middlewares:
    redirect-to-https:
      redirectScheme:
        scheme: https
        permanent: true

    authelia-forwardauth:
      forwardAuth:
        address: "http://authelia:9091/api/verify?rd=https://${AUTH_DOMAIN}/"
        trustForwardHeader: true
        authResponseHeaders:
          - Remote-User
          - Remote-Groups
          - Remote-Name
          - Remote-Email

  routers:
    # HTTP (80) routers MUST have a service even if only redirecting
    portal80:
      rule: "Host(\`${PORTAL_DOMAIN}\`)"
      entryPoints: [ web ]
      middlewares: [ redirect-to-https ]
      service: noop@internal

    authelia80:
      rule: "Host(\`${AUTH_DOMAIN}\`)"
      entryPoints: [ web ]
      middlewares: [ redirect-to-https ]
      service: noop@internal

    # HTTPS (443)
    # portal reuses the SAN cert issued by the authelia router
    portal:
      rule: "Host(\`${PORTAL_DOMAIN}\`)"
      entryPoints: [ websecure ]
      service: nodered
      middlewares: [ authelia-forwardauth ]
      tls: {}

    # authelia issues ONE SAN cert for portal+auth
    authelia:
      rule: "Host(\`${AUTH_DOMAIN}\`)"
      entryPoints: [ websecure ]
      service: authelia-svc
      tls:
        certResolver: le
        domains:
          - main: ${PORTAL_DOMAIN}
            sans:
              - ${AUTH_DOMAIN}

  services:
    nodered:
      loadBalancer:
        servers:
          - url: "${NODERED_URL}"

    authelia-svc:
      loadBalancer:
        servers:
          - url: "http://authelia:9091"
YAML
}

write_authelia_users(){
  local hash; hash="$(hash_password_bcrypt "$AUTH_PASS")"
  cat >"$AUTHELIA_DIR/users_database.yml" <<YAML
users:
  ${AUTH_USER}:
    displayname: "${AUTH_USER}"
    password: "${hash}"
    email: "${AUTH_EMAIL}"
    groups:
      - admins
      - users
YAML
  chown -R 1000:1000 "$AUTHELIA_DIR"
  chmod 640 "$AUTHELIA_DIR/users_database.yml"
}

write_authelia_config(){
  local base_zone; base_zone="$(calc_base_zone "$PORTAL_DOMAIN")"
  cat >"$AUTHELIA_DIR/configuration.yml" <<YAML
server:
  address: "tcp://0.0.0.0:9091/"

log:
  level: info

session:
  cookies:
    - domain: "${base_zone}"
      authelia_url: "https://${AUTH_DOMAIN}"
      default_redirection_url: "https://${PORTAL_DOMAIN}"
      name: "authelia_session"
      same_site: lax
      inactivity: "15m"
      expiration: "8h"
      remember_me: "30d"

authentication_backend:
  file:
    path: "/config/users_database.yml"

storage:
  encryption_key: "$(openssl rand -hex 64)"
  local:
    path: "/config/db.sqlite3"

notifier:
  filesystem:
    filename: "/config/notification.txt"

identity_validation:
  reset_password:
    jwt_secret: "$(openssl rand -hex 64)"
YAML

  # Access control
  cat >>"$AUTHELIA_DIR/configuration.yml" <<YAML

access_control:
  default_policy: deny
  rules:
    - domain: ["${PORTAL_DOMAIN}"]
      policy: one_factor
YAML

  # Optional lockout (regulation)
  if [[ "${ENABLE_REGULATION,,}" == "y" ]]; then
    cat >>"$AUTHELIA_DIR/configuration.yml" <<YAML

regulation:
  max_retries: ${REG_MAX_RETRIES}
  find_time: ${REG_FIND_TIME}
  ban_time: ${REG_BAN_TIME}
YAML
  fi

  chown -R 1000:1000 "$AUTHELIA_DIR"
}

write_env(){
  mkdir -p "$BASE"
  printf 'TZ=%s\n' "$TZ" > "$ENV_FILE"
}

main(){
  require_root
  ensure_docker

  prompt_inputs
  export TZ

  if [[ "${NUKE,,}" == "y" ]]; then
    (cd "$BASE" 2>/dev/null && docker compose down || true)
    rm -rf "$BASE"
  fi

  mkdir -p "$TRAEFIK_DIR" "$LE_DIR" "$AUTHELIA_DIR"

  write_env
  : >"$ACME_FILE"
  chmod 600 "$ACME_FILE"
  chown root:root "$ACME_FILE"

  write_compose
  write_traefik_static
  sed -i "s/\${LE_EMAIL}/$(printf '%s' "$LE_EMAIL" | sed 's/[&/]/\\&/g')/" "$TRAEFIK_STATIC"
  write_traefik_dynamic
  write_authelia_users
  write_authelia_config

  (cd "$BASE" && docker compose up -d)

  echo
  echo "Wait one minute before accessing portal via an external computer"  
  echo "https://${AUTH_DOMAIN}"

  echo
  echo "== Quick checks == From an external computer"
  echo "curl -sSI http://${AUTH_DOMAIN}/.well-known/acme-challenge/TEST | head -n1"
  echo "curl -I https://${AUTH_DOMAIN}"

  echo
  echo "== Cert troubleshooting =="
  echo "docker compose logs -f traefik | egrep -i 'acme|certificate|challenge|letsencrypt|error'"
  echo "echo | openssl s_client -showcerts -servername ${AUTH_DOMAIN} -connect ${AUTH_DOMAIN}:443 | awk '/s:|i:|Verify return code/'"
}

main "$@"
