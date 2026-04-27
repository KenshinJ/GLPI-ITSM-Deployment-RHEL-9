#!/usr/bin/env bash
# =============================================================================
# GLPI 10.0.24 — Production Deployment
# Target: RHEL 9.7 + Rootless Podman (native) + systemd
#
# Usage:
#   sudo bash glpi.sh [--env /path/to/glpi.env] [--skip-build] [--skip-db]
#
# Flags:
#   --env FILE      Path to environment file  (default: ./glpi.env)
#   --skip-build    Skip podman image build    (use existing image)
#   --skip-db       Skip db:install phase      (DB already initialized)
#   --dry-run       Print actions, write no files, start no services
#
# Idempotent: safe to re-run. Each section is self-guarding.
#
# RHEL 9.7 NOTES:
#   • podman-compose is NOT used. All container orchestration is done via
#     native podman commands (podman network, podman volume, podman run).
#     This avoids the podman-compose AppStream availability problem entirely.
#   • A shared podman network (glpi-net) connects the three containers.
#   • Container startup order and health-gating is handled by the
#     stack_up() function (waits for DB healthy before starting app, etc.).
#   • systemd unit (glpi-compose.service) drives start/stop/reload using
#     individual "podman start / podman stop" calls — no compose needed.
#   • Section 9 (previously compose.yaml) now writes a human-readable
#     reference file only; it is NOT consumed by any tooling.
#   • nginx http2: "listen ... ssl http2" syntax kept for nginx < 1.25.
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INF]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERR]${NC}    $*" >&2; exit 1; }
ok()      { echo -e "  ${GREEN}[OK]${NC}    $*"; }
section() {
  echo -e "\n${CYAN}${BOLD}══════════════════════════════════════════════════${NC}"
  echo -e "${CYAN}${BOLD}  $*${NC}"
  echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════${NC}"
}

# ── Argument parsing ──────────────────────────────────────────────────────────
ENV_FILE="$(dirname "$0")/glpi.env"
SKIP_BUILD=0
SKIP_DB=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)        ENV_FILE="$2"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --skip-db)    SKIP_DB=1; shift ;;
    --dry-run)    DRY_RUN=1; shift ;;
    *) die "Unknown flag: $1. Usage: sudo bash glpi.sh [--env FILE] [--skip-build] [--skip-db] [--dry-run]" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0"
[[ -f "${ENV_FILE}" ]] || die "Environment file not found: ${ENV_FILE}\nCopy glpi.env.example to glpi.env and fill in your values."

# ── Detect operator account (the real user behind sudo) ───────────────────────
_resolve_operator() {
  local candidate="${SUDO_USER:-}"
  if [[ -z "${candidate}" || "${candidate}" == "root" ]]; then
    local loginuid
    loginuid="$(cat /proc/self/loginuid 2>/dev/null || echo '')"
    if [[ -n "${loginuid}" && "${loginuid}" != "4294967295" && "${loginuid}" != "0" ]]; then
      candidate="$(getent passwd "${loginuid}" | cut -d: -f1 2>/dev/null || echo '')"
    fi
  fi
  if [[ -z "${candidate}" || "${candidate}" == "root" ]]; then
    candidate="$(logname 2>/dev/null || echo '')"
  fi
  echo "${candidate}"
}

OPERATOR_USER="$(_resolve_operator)"
[[ -z "${OPERATOR_USER}" || "${OPERATOR_USER}" == "root" ]] && \
  die "Could not determine the operator account.\nRun as: sudo bash $0 (not from a root shell)"

# ── Load environment ──────────────────────────────────────────────────────────
# shellcheck source=/dev/null
source "${ENV_FILE}"

# ── Sanitize env values ───────────────────────────────────────────────────────
_strip_md_link() { sed -E 's/\[([^]]+)\]\([^)]+\)/\1/g'; }
for _var in GLPI_HOSTNAME MAIL_HOST SMTP_HOST SMTP_FROM ZABBIX_HOST IDM_HOST; do
  _val="${!_var:-}"
  if [[ -n "$_val" ]]; then
    _clean="$(echo "${_val}" | _strip_md_link)"
    if [[ "$_clean" != "$_val" ]]; then
      warn "ENV: ${_var} contained markdown formatting — sanitized to: ${_clean}"
      printf -v "${_var}" '%s' "${_clean}"
    fi
  fi
done
unset _var _val _clean

# Derived values (not in .env to avoid duplication)
GLPI_WEBROOT="${GLPI_BASE}/webroot"
IMG_GLPI_APP="localhost/glpi-app:${GLPI_VERSION}"
GLPI_NET="${COMPOSE_PROJECT}_glpi-net"

# Volume names — prefixed with project name to match compose conventions
VOL_DB="${COMPOSE_PROJECT}_glpi-mariadb"
VOL_CONFIG="${COMPOSE_PROJECT}_glpi-config"
VOL_FILES="${COMPOSE_PROJECT}_glpi-files"
VOL_LOG="${COMPOSE_PROJECT}_glpi-log"

SECRETS_DIR="${GLPI_BASE}/secrets"

[[ $DRY_RUN -eq 1 ]] && warn "DRY-RUN mode — no files written, no services started."

# ── Utilities ─────────────────────────────────────────────────────────────────
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

write_if_differs() {
  local target="$1"
  local mode="${2:-644}"
  local tmp="${target}.tmp.$$"
  local old_umask
  old_umask=$(umask)

  if [[ $DRY_RUN -eq 1 ]]; then
    info "  [dry-run] would write: ${target}"
    cat > /dev/null
    return
  fi

  umask 077
  mkdir -p "$(dirname "${target}")"
  cat > "${tmp}"
  umask "${old_umask}"
  chmod "${mode}" "${tmp}"
  if cmp -s "${target}" "${tmp}" 2>/dev/null; then
    rm -f "${tmp}"
  else
    mv -f "${tmp}" "${target}"
    info "  wrote: ${target}"
  fi
}

# ---------------------------------------------------------------------------
# ROOTLESS PODMAN HELPERS
# All container operations run as GLPI_USER via runuser so they operate in
# that user's rootless Podman namespace. Root's Podman namespace is separate.
# ---------------------------------------------------------------------------
_glpi_uid() { id -u "${GLPI_USER}"; }

run_podman() {
  # run_podman "subcommand args..."  — executes as GLPI_USER
  local uid
  uid="$(_glpi_uid)"
  runuser -l "${GLPI_USER}" -s /bin/bash -c \
    "XDG_RUNTIME_DIR=/run/user/${uid} \
     DOCKER_HOST=unix:///run/user/${uid}/podman/podman.sock \
     podman $*"
}

# ---------------------------------------------------------------------------
# NETWORK & VOLUME HELPERS
# ---------------------------------------------------------------------------
_ensure_network() {
  if ! run_podman "network exists ${GLPI_NET}" 2>/dev/null; then
    run_podman "network create ${GLPI_NET}"
    ok "Created podman network: ${GLPI_NET}"
  else
    ok "Network already exists: ${GLPI_NET}"
  fi
}

_ensure_volumes() {
  for vol in "${VOL_DB}" "${VOL_CONFIG}" "${VOL_FILES}" "${VOL_LOG}"; do
    if ! run_podman "volume exists ${vol}" 2>/dev/null; then
      run_podman "volume create \
        --label com.glpi.managed=true \
        --label com.glpi.project=${COMPOSE_PROJECT} \
        ${vol}"
      ok "Created volume: ${vol}"
    else
      ok "Volume exists: ${vol}"
    fi
  done
}

# ---------------------------------------------------------------------------
# STACK UP — start containers in dependency order with health gating
# ---------------------------------------------------------------------------
stack_up() {
  [[ $DRY_RUN -eq 1 ]] && { info "[dry-run] would start stack"; return; }

  _ensure_network
  _ensure_volumes

  # ── glpi-db ────────────────────────────────────────────────────────────
  if ! run_podman "inspect glpi-db --format '{{.State.Status}}'" 2>/dev/null | grep -q running; then
    run_podman "rm -f glpi-db" 2>/dev/null || true
    run_podman "run -d \
      --name glpi-db \
      --network ${GLPI_NET} \
      --restart always \
      --env-file ${SECRETS_DIR}/db.env \
      --volume ${VOL_DB}:/var/lib/mysql:z \
      --health-cmd 'mysqladmin ping -h 127.0.0.1 -u root --password=\$MARIADB_ROOT_PASSWORD || exit 1' \
      --health-interval 10s \
      --health-timeout 5s \
      --health-retries 10 \
      --health-start-period 30s \
      ${IMG_MARIADB}"
    ok "Started glpi-db"
  else
    ok "glpi-db already running"
  fi

  # ── glpi-app ───────────────────────────────────────────────────────────
  if ! run_podman "inspect glpi-app --format '{{.State.Status}}'" 2>/dev/null | grep -q running; then
    run_podman "rm -f glpi-app" 2>/dev/null || true
    run_podman "run -d \
      --name glpi-app \
      --network ${GLPI_NET} \
      --restart always \
      --env-file ${SECRETS_DIR}/app.env \
      --volume ${VOL_CONFIG}:/etc/glpi:z \
      --volume ${VOL_FILES}:/var/lib/glpi:z \
      --volume ${VOL_LOG}:/var/log/glpi:z \
      --volume ${GLPI_WEBROOT}:/srv/glpi-webroot:z,shared \
      --volume ${GLPI_BASE}/php-conf/glpi.ini:/usr/local/etc/php/conf.d/glpi.ini:ro,z \
      --volume ${GLPI_BASE}/php-conf/www.conf:/usr/local/etc/php-fpm.d/www.conf:ro,z \
      --volume ${GLPI_BASE}/logs/php-fpm-slow.log:/var/log/glpi/php-fpm-slow.log:z \
      --health-cmd \"bash -c '</dev/tcp/127.0.0.1/9000' 2>/dev/null && echo ok || exit 1\" \
      --health-interval 15s \
      --health-timeout 5s \
      --health-retries 5 \
      --health-start-period 60s \
      ${IMG_GLPI_APP}"
    ok "Started glpi-app"
  else
    ok "glpi-app already running"
  fi

  # ── glpi-nginx ─────────────────────────────────────────────────────────
  if ! run_podman "inspect glpi-nginx --format '{{.State.Status}}'" 2>/dev/null | grep -q running; then
    run_podman "rm -f glpi-nginx" 2>/dev/null || true
    run_podman "run -d \
      --name glpi-nginx \
      --network ${GLPI_NET} \
      --restart always \
      --publish 127.0.0.1:${POD_HOST_PORT}:${COMPOSE_PORT} \
      --volume ${GLPI_BASE}/nginx-conf/glpi.conf:/etc/nginx/conf.d/default.conf:ro,z \
      --volume ${GLPI_WEBROOT}:/srv/glpi-webroot:ro,z,shared \
      --health-cmd \"curl -sf http://127.0.0.1:${COMPOSE_PORT}/healthz || exit 1\" \
      --health-interval 15s \
      --health-timeout 5s \
      --health-retries 5 \
      --health-start-period 30s \
      ${IMG_NGINX}"
    ok "Started glpi-nginx"
  else
    ok "glpi-nginx already running"
  fi
}

# ---------------------------------------------------------------------------
# STACK DOWN — stop and remove all three containers (volumes/network kept)
# ---------------------------------------------------------------------------
stack_down() {
  local port="${POD_HOST_PORT}"

  for ctr in glpi-nginx glpi-app glpi-db; do
    run_podman "stop --time 10 ${ctr}" 2>/dev/null || true
    run_podman "rm   -f        ${ctr}" 2>/dev/null || true
    podman rm -f "${ctr}" 2>/dev/null || true
  done

  pkill -f "rootlessport.*${port}" 2>/dev/null || true
  runuser -l "${GLPI_USER}" -s /bin/bash -c \
    "pkill -f 'rootlessport.*${port}'" 2>/dev/null || true
  fuser -k "${port}/tcp" 2>/dev/null || true

  sleep 2

  if ss -tlnp 2>/dev/null | grep -q ":${port}\\b"; then
    warn "Port ${port} still bound after full teardown."
  fi
}

wait_container_status() {
  local name="$1" want="$2" tries="${3:-60}" sleep_s="${4:-2}"
  for _ in $(seq 1 "${tries}"); do
    local s
    s="$(run_podman "inspect ${name} --format '{{.State.Status}}'" 2>/dev/null || echo none)"
    [[ "$s" == "$want" ]] && return 0
    sleep "${sleep_s}"
  done
  return 1
}

# ── Preflight checks ──────────────────────────────────────────────────────────
section "0. Preflight checks"

if ss -tlnp 2>/dev/null | grep -q ":${POD_HOST_PORT}\\b"; then
  warn "Port ${POD_HOST_PORT} already bound — clearing stale containers..."
  stack_down
  if ss -tlnp 2>/dev/null | grep -q ":${POD_HOST_PORT}\\b"; then
    die "Port ${POD_HOST_PORT} still in use after all cleanup attempts."
  fi
  ok "Port ${POD_HOST_PORT} cleared."
else
  ok "Port ${POD_HOST_PORT} is free."
fi

ok "Preflight checks passed."

# ── Section 1: Packages ───────────────────────────────────────────────────────
section "1. Host packages and services"

[[ $DRY_RUN -eq 0 ]] && dnf module enable -y container-tools 2>/dev/null || \
  warn "container-tools module enable failed — repo may already be active."

[[ $DRY_RUN -eq 0 ]] && dnf update -y

dnf_pkgs=(
  podman
  netavark aardvark-dns
  firewalld nginx openssl
  jq curl nftables rsync
  policycoreutils-python-utils container-selinux
  checkpolicy policycoreutils setools-console
  acl psmisc iproute tzdata
)

[[ $DRY_RUN -eq 0 ]] && dnf install -y "${dnf_pkgs[@]}"

need_cmd podman
need_cmd nginx
need_cmd firewall-cmd
need_cmd jq
need_cmd curl
need_cmd fuser
need_cmd ss

[[ $DRY_RUN -eq 0 ]] && {
  systemctl enable --now firewalld
  systemctl enable --now podman.socket
  systemctl enable --now nginx
  ok "Host services enabled."
}

# ── Section 2: Service user ──────────────────────────��────────────────────────
section "2. Rootless service user: ${GLPI_USER}"

if ! id "${GLPI_USER}" &>/dev/null; then
  [[ $DRY_RUN -eq 0 ]] && \
    useradd -r -u "${GLPI_UID}" -g "${GLPI_GID}" -d "${GLPI_BASE}" \
            -s /sbin/nologin -c "GLPI service account" "${GLPI_USER}" 2>/dev/null || \
    useradd -r -d "${GLPI_BASE}" -s /sbin/nologin -c "GLPI service account" "${GLPI_USER}"
  ok "Created user ${GLPI_USER}"
else
  ok "User ${GLPI_USER} already exists."
fi

[[ $DRY_RUN -eq 0 ]] && {
  if ! groups "${OPERATOR_USER}" 2>/dev/null | grep -qw wheel; then
    usermod -aG wheel "${OPERATOR_USER}"
    ok "Added ${OPERATOR_USER} to wheel group."
  else
    ok "${OPERATOR_USER} is already in wheel."
  fi
  loginctl enable-linger "${GLPI_USER}"
}

if ! grep -q "^${GLPI_USER}:" /etc/subuid 2>/dev/null; then
  [[ $DRY_RUN -eq 0 ]] && \
    usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "${GLPI_USER}"
  ok "Subuid/subgid allocated for ${GLPI_USER}"
fi

[[ $DRY_RUN -eq 0 ]] && {
  GLPI_UID_VAL="$(_glpi_uid)"
  mkdir -p "/run/user/${GLPI_UID_VAL}"
  chown "${GLPI_USER}:${GLPI_USER}" "/run/user/${GLPI_UID_VAL}"

  runuser -l "${GLPI_USER}" -s /bin/bash -c \
    "XDG_RUNTIME_DIR=/run/user/${GLPI_UID_VAL} \
     systemctl --user enable --now podman.socket" 2>/dev/null && \
    ok "Rootless podman.socket enabled for ${GLPI_USER}." || \
    warn "Could not enable rootless podman.socket — continuing."

  GLPI_HOME="$(getent passwd "${GLPI_USER}" | cut -d: -f6)"
  PROFILE_D="${GLPI_HOME}/.bashrc.d"
  mkdir -p "${PROFILE_D}"
  cat > "${PROFILE_D}/podman-socket.sh" <<SOCKEOF
export XDG_RUNTIME_DIR=/run/user/${GLPI_UID_VAL}
export DOCKER_HOST=unix:///run/user/${GLPI_UID_VAL}/podman/podman.sock
SOCKEOF
  chown -R "${GLPI_USER}:${GLPI_USER}" "${PROFILE_D}"
  ok "DOCKER_HOST written to ${PROFILE_D}/podman-socket.sh"

  BASHRC="${GLPI_HOME}/.bashrc"
  touch "${BASHRC}"
  grep -q "bashrc.d/podman-socket.sh" "${BASHRC}" 2>/dev/null || \
    echo 'for _f in ~/.bashrc.d/*.sh; do [ -r "$_f" ] && . "$_f"; done' >> "${BASHRC}"
  chown "${GLPI_USER}:${GLPI_USER}" "${BASHRC}"

  write_if_differs "/etc/sudoers.d/glpi-podman" 440 <<SUDOEOF
Defaults:${OPERATOR_USER} env_keep += "XDG_RUNTIME_DIR DOCKER_HOST"
Defaults:${GLPI_USER} !requiretty
%wheel ALL=(${GLPI_USER}) NOPASSWD: /usr/bin/podman
SUDOEOF
  visudo -cf /etc/sudoers.d/glpi-podman && \
    ok "sudoers drop-in written." || {
    warn "sudoers syntax check failed — removing."
    rm -f /etc/sudoers.d/glpi-podman
  }

  write_if_differs "/usr/local/bin/podman-glpi" 755 <<WRAPEOF
#!/usr/bin/env bash
GLPI_USER="${GLPI_USER}"
GLPI_UID=\$(id -u "\${GLPI_USER}" 2>/dev/null) || { echo "User \${GLPI_USER} not found" >&2; exit 1; }
XDG_RUNTIME_DIR="/run/user/\${GLPI_UID}"
DOCKER_HOST="unix:///run/user/\${GLPI_UID}/podman/podman.sock"
export XDG_RUNTIME_DIR DOCKER_HOST
exec sudo -u "\${GLPI_USER}" \
  XDG_RUNTIME_DIR="\${XDG_RUNTIME_DIR}" \
  DOCKER_HOST="\${DOCKER_HOST}" \
  /usr/bin/podman "\$@"
WRAPEOF
  ok "Convenience wrapper written: /usr/local/bin/podman-glpi"
}

# ── Section 3: Firewall ───────────────────────────────────────────────────────
section "3. Firewall rules"

[[ $DRY_RUN -eq 0 ]] && {
  for port in "${NGINX_HTTP_PORT}/tcp" "${NGINX_HTTPS_PORT}/tcp"; do
    firewall-cmd --query-port="${port}" -q 2>/dev/null || \
      firewall-cmd --permanent --add-port="${port}"
  done
  firewall-cmd --reload
  ok "Firewall rules applied."
}

hostnamectl set-hostname "${GLPI_HOSTNAME}"

# ── Section 4: /etc/hosts injection ──────────────────────────────────────────
section "4. /etc/hosts — internal service hosts"

inject_host() {
  local ip="$1" host="$2"
  if grep -qP "^\s*${ip}\s+.*\b${host}\b" /etc/hosts 2>/dev/null; then
    ok "${host} already in /etc/hosts"
  else
    [[ $DRY_RUN -eq 0 ]] && echo "${ip}  ${host}" >> /etc/hosts
    ok "Injected: ${ip}  ${host}"
  fi
}

inject_host "${MAIL_IP}"   "${MAIL_HOST}"
inject_host "${ZABBIX_IP}" "${ZABBIX_HOST}"
inject_host "${IDM_IP}"    "${IDM_HOST}"
inject_host "${GLPI_IP}"   "${GLPI_HOSTNAME}"

# ── Section 5: SELinux ────────────────────────────────────────────────────────
section "5. SELinux — custom policy for rootless Podman"

[[ $DRY_RUN -eq 0 ]] && {
  setsebool -P httpd_can_network_connect 1
  setsebool -P container_manage_cgroup   1 2>/dev/null || true
  setsebool -P nis_enabled               1 2>/dev/null || true
  ok "SELinux booleans set."
}

# ── Section 6: Directories and secrets ───────────────────────────────────────
section "6. Directories and secrets"

[[ $DRY_RUN -eq 0 ]] && {
  mkdir -p "${GLPI_BASE}"/{nginx-conf,php-conf,secrets,logs,backups}
  mkdir -p "${GLPI_WEBROOT}"
  mkdir -p "${BACKUP_DIR}"
  chown -R "${GLPI_USER}:${GLPI_USER}" "${GLPI_BASE}"
  chown -R "${GLPI_USER}:${GLPI_USER}" "${BACKUP_DIR}"
  chmod 750 "${GLPI_BASE}"
  chmod 700 "${SECRETS_DIR}"
  chmod 755 "${GLPI_WEBROOT}"
  chmod 750 "${BACKUP_DIR}"
}

gen_secret() {
  local file="$1"
  local hint="${2:-}"
  if [[ ! -f "${file}" ]]; then
    if [[ -n "${hint}" ]]; then
      echo -n "${hint}"
    else
      openssl rand -base64 32
    fi > "${file}"
    [[ $DRY_RUN -eq 0 ]] && chmod 400 "${file}" && chown "${GLPI_USER}:${GLPI_USER}" "${file}"
    ok "Generated: ${file}"
  else
    ok "Exists:    ${file}"
  fi
}

[[ $DRY_RUN -eq 0 ]] && {
  gen_secret "${SECRETS_DIR}/db-root-password" "${DB_ROOT_PASSWORD_HINT:-}"
  gen_secret "${SECRETS_DIR}/db-password"      "${DB_PASSWORD_HINT:-}"
}

DB_ROOT_PW="$(cat "${SECRETS_DIR}/db-root-password" 2>/dev/null || echo 'placeholder')"
DB_PW="$(cat "${SECRETS_DIR}/db-password" 2>/dev/null || echo 'placeholder')"

write_if_differs "${SECRETS_DIR}/db.env" 400 <<EOF
MARIADB_ROOT_PASSWORD=${DB_ROOT_PW}
MARIADB_DATABASE=${MARIADB_DATABASE}
MARIADB_USER=${MARIADB_USER}
MARIADB_PASSWORD=${DB_PW}
MARIADB_CHARACTER_SET_SERVER=utf8mb4
MARIADB_COLLATION_SERVER=utf8mb4_unicode_ci
EOF

write_if_differs "${SECRETS_DIR}/app.env" 400 <<EOF
DB_HOST=glpi-db
DB_PORT=3306
DB_NAME=${MARIADB_DATABASE}
DB_USER=${MARIADB_USER}
DB_PASSWORD=${DB_PW}
EOF

[[ $DRY_RUN -eq 0 ]] && {
  chown "${GLPI_USER}:${GLPI_USER}" \
    "${SECRETS_DIR}/db.env" \
    "${SECRETS_DIR}/app.env" 2>/dev/null || true
  touch "${GLPI_BASE}/logs/php-fpm-slow.log"
  chmod 664 "${GLPI_BASE}/logs/php-fpm-slow.log"
}

# ── Section 7: PHP and nginx configs ──────────────────────────────────────────
section "7. Container configs (PHP-FPM, nginx)"

write_if_differs "${GLPI_BASE}/php-conf/www.conf" <<'WWWEOF'
[www]
user  = www-data
group = www-data
listen = 0.0.0.0:9000
pm.status_path = /status
pm = dynamic
pm.max_children      = 20
pm.start_servers     = 4
pm.min_spare_servers = 2
pm.max_spare_servers = 8
pm.max_requests      = 500
slowlog = /var/log/glpi/php-fpm-slow.log
request_slowlog_timeout = 5s
WWWEOF

write_if_differs "${GLPI_BASE}/php-conf/glpi.ini" <<'PHPINIEOF'
memory_limit            = 256M
upload_max_filesize     = 20M
post_max_size           = 20M
max_execution_time      = 300
date.timezone           = UTC
session.cookie_httponly = On
session.cookie_secure   = On
session.use_strict_mode = On
opcache.enable                  = 1
opcache.memory_consumption      = 128
opcache.interned_strings_buffer = 16
opcache.max_accelerated_files   = 10000
opcache.validate_timestamps     = 0
opcache.save_comments           = 1
PHPINIEOF

write_if_differs "${GLPI_BASE}/nginx-conf/glpi.conf" <<NGINXEOF
server {
    listen ${COMPOSE_PORT};
    server_name _;
    root  /srv/glpi-webroot;
    index index.php;

    location = /healthz {
        access_log off;
        return 200 "ok\n";
        add_header Content-Type text/plain;
    }

    location ~ ^/(config|files|vendor|scripts|tests|install)/ { deny all; return 404; }
    location ~ /\\.ht { deny all; }

    location ~ \\.php\$ {
        include             fastcgi_params;
        fastcgi_split_path_info ^(.+\\.php)(/.*)\$;
        fastcgi_pass        glpi-app:9000;
        fastcgi_index       index.php;
        fastcgi_param SCRIPT_FILENAME  \$realpath_root\$fastcgi_script_name;
        fastcgi_param DOCUMENT_ROOT    \$realpath_root;
        fastcgi_param PATH_INFO        \$fastcgi_path_info;
        fastcgi_param HTTP_PROXY       "";
        fastcgi_param HTTPS            on;
        fastcgi_param HTTP_X_FORWARDED_PROTO https;
        fastcgi_read_timeout  300;
        fastcgi_send_timeout  300;
        fastcgi_buffers       16 16k;
        fastcgi_buffer_size   32k;
    }

    location ~* \\.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot|map)\$ {
        expires 7d;
        add_header Cache-Control "public";
        access_log off;
        try_files \$uri =404;
    }

    location / {
        try_files \$uri \$uri/ /public/index.php\$is_args\$args;
    }
}
NGINXEOF

# ── Section 8: Dockerfile ─────────────────────────────────────────────────────
section "8. Dockerfile and entrypoint"

write_if_differs "${GLPI_BASE}/Dockerfile.glpi" <<DOCKEREOF
FROM ${IMG_PHP}

RUN apk add --no-cache \\
      icu-libs libpng libjpeg-turbo libzip openldap libxml2 oniguruma curl bash rsync su-exec

RUN apk add --no-cache --virtual .build-deps \\
      autoconf g++ make libpng-dev libjpeg-turbo-dev libxml2-dev libzip-dev icu-dev oniguruma-dev openldap-dev \\
    && docker-php-ext-configure gd --with-jpeg \\
    && docker-php-ext-install -j\$(nproc) pdo_mysql mysqli gd intl zip xml mbstring ldap opcache exif bcmath ctype fileinfo \\
    && pecl install apcu \\
    && docker-php-ext-enable apcu \\
    && apk del .build-deps

RUN curl -fsSL -o /tmp/glpi.tgz "https://github.com/glpi-project/glpi/releases/download/${GLPI_VERSION}/glpi-${GLPI_VERSION}.tgz" \\
    && tar -xzf /tmp/glpi.tgz -C /var/www/ \\
    && rm /tmp/glpi.tgz \\
    && chown -R www-data:www-data /var/www/glpi

RUN mkdir -p /etc/glpi /var/lib/glpi /var/log/glpi \\
    && cp -r /var/www/glpi/config/. /etc/glpi/ \\
    && cp -r /var/www/glpi/files/.  /var/lib/glpi/ \\
    && rm -rf /var/www/glpi/config /var/www/glpi/files \\
    && ln -sfn /etc/glpi     /var/www/glpi/config \\
    && ln -sfn /var/lib/glpi /var/www/glpi/files \\
    && chown -R www-data:www-data /etc/glpi /var/lib/glpi /var/log/glpi

COPY glpi-local_define.php /var/www/glpi/inc/local_define.php
RUN mkdir -p /opt/glpi-snapshot && cp -a /var/www/glpi/. /opt/glpi-snapshot/ && chown -R www-data:www-data /opt/glpi-snapshot

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

VOLUME ["/etc/glpi", "/var/lib/glpi", "/var/log/glpi"]
EXPOSE 9000

ENTRYPOINT ["/entrypoint.sh"]
CMD ["php-fpm", "--nodaemonize"]
DOCKEREOF

write_if_differs "${GLPI_BASE}/entrypoint.sh" 755 <<'ENTRYEOF'
#!/bin/sh
set -e

SNAPSHOT="/opt/glpi-snapshot"
WEBROOT="/srv/glpi-webroot"
SENTINEL="${WEBROOT}/.glpi-initialized"

if [ -z "$(ls -A /etc/glpi 2>/dev/null)" ]; then
  cp -a "${SNAPSHOT}/config/." /etc/glpi/ 2>/dev/null || true
fi

if [ -z "$(ls -A /var/lib/glpi 2>/dev/null)" ]; then
  rsync -a --no-links "${SNAPSHOT}/files/" /var/lib/glpi/ 2>/dev/null || true
fi

if [ ! -f "${SENTINEL}" ]; then
  mkdir -p "${WEBROOT}"
  rsync -a --delete --exclude='.glpi-initialized' "${SNAPSHOT}/" "${WEBROOT}/"
  rm -f "${WEBROOT}/install/install.php"
  touch "${SENTINEL}"
fi

chown -R www-data:www-data /etc/glpi /var/lib/glpi /var/log/glpi

if [ ! -f "${WEBROOT}/.glpi-chown-done" ]; then
  chown -R www-data:www-data "${WEBROOT}"
  touch "${WEBROOT}/.glpi-chown-done"
fi

for d in _cache _cron _dumps _graphs _lock _pictures _plugins _rss _sessions _tmp _uploads; do
  mkdir -p "/var/lib/glpi/${d}"
  chown www-data:www-data "/var/lib/glpi/${d}"
  chmod 770 "/var/lib/glpi/${d}"
done

exec su-exec www-data "$@"
ENTRYEOF

write_if_differs "${GLPI_BASE}/glpi-local_define.php" <<'PHPEOF'
<?php
define('GLPI_CONFIG_DIR', '/etc/glpi/');
define('GLPI_VAR_DIR',    '/var/lib/glpi/');
define('GLPI_LOG_DIR',    '/var/log/glpi/');
PHPEOF

# ── Section 9: Host nginx TLS proxy ───────────────────────────────────────────
section "9. Host nginx TLS proxy"

CERT_DIR="/etc/pki/tls/certs"
KEY_DIR="/etc/pki/tls/private"

if [[ ! -f "${CERT_DIR}/${GLPI_HOSTNAME}.crt" ]]; then
  [[ $DRY_RUN -eq 0 ]] && \
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout "${KEY_DIR}/${GLPI_HOSTNAME}.key" \
    -out    "${CERT_DIR}/${GLPI_HOSTNAME}.crt" \
    -subj   "/CN=${GLPI_HOSTNAME}" 2>/dev/null
  [[ $DRY_RUN -eq 0 ]] && chmod 400 "${KEY_DIR}/${GLPI_HOSTNAME}.key"
  ok "Certificate generated."
fi

write_if_differs "/etc/nginx/conf.d/glpi.conf" <<HOSTNGINXEOF
upstream glpi_compose {
    server 127.0.0.1:8081;
    keepalive 16;
}

server {
    listen 0.0.0.0:${NGINX_HTTP_PORT};
    server_name ${GLPI_HOSTNAME};
    return 301 https://\$host:${NGINX_HTTPS_PORT}\$request_uri;
}

server {
    listen 0.0.0.0:${NGINX_HTTPS_PORT} ssl http2;
    server_name ${GLPI_HOSTNAME};

    ssl_certificate     ${CERT_DIR}/${GLPI_HOSTNAME}.crt;
    ssl_certificate_key ${KEY_DIR}/${GLPI_HOSTNAME}.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 10m;

    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header X-Content-Type-Options nosniff always;
    client_max_body_size 20M;

    location / {
        proxy_pass             http://glpi_compose;
        proxy_http_version     1.1;
        proxy_set_header       Host              \$http_host;
        proxy_set_header       X-Forwarded-Proto https;
        proxy_set_header       X-Real-IP         \$remote_addr;
        proxy_set_header       Connection        "";
        proxy_read_timeout     300s;
    }
}
HOSTNGINXEOF

[[ $DRY_RUN -eq 0 ]] && nginx -t && systemctl restart nginx && ok "nginx configured and restarted."

# ── Section 10: systemd unit ──────────────────────────────────────────────────
section "10. systemd unit — glpi-compose.service"

write_if_differs "/etc/systemd/system/glpi-compose.service" <<SVCEOF
[Unit]
Description=GLPI Podman Stack (rootless)
After=network-online.target firewalld.service

[Service]
Type=forking
User=root

ExecStart=/usr/bin/bash -c 'runuser -l ${GLPI_USER} -s /bin/bash -c "XDG_RUNTIME_DIR=/run/user/\$(id -u ${GLPI_USER}) DOCKER_HOST=unix:///run/user/\$(id -u ${GLPI_USER})/podman/podman.sock bash /opt/glpi/start-stack.sh"'
ExecReload=/usr/bin/bash -c 'runuser -l ${GLPI_USER} -s /bin/bash -c "XDG_RUNTIME_DIR=/run/user/\$(id -u ${GLPI_USER}) DOCKER_HOST=unix:///run/user/\$(id -u ${GLPI_USER})/podman/podman.sock bash /opt/glpi/start-stack.sh"'
ExecStop=/usr/bin/bash -c 'runuser -l ${GLPI_USER} -s /bin/bash -c "XDG_RUNTIME_DIR=/run/user/\$(id -u ${GLPI_USER}) DOCKER_HOST=unix:///run/user/\$(id -u ${GLPI_USER})/podman/podman.sock podman stop --time 30 glpi-nginx glpi-app glpi-db"'

TimeoutStartSec=300
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
SVCEOF

[[ $DRY_RUN -eq 0 ]] && systemctl daemon-reload && systemctl enable glpi-compose.service && ok "systemd unit enabled."

# ── Section 11: Build image (if needed) ───────────────────────────────────────
section "11. Build GLPI container image"

if [[ $SKIP_BUILD -eq 0 ]]; then
  if [[ $DRY_RUN -eq 0 ]]; then
    if run_podman "image exists ${IMG_GLPI_APP}" 2>/dev/null; then
      warn "Image ${IMG_GLPI_APP} already exists — skipping build."
    else
      info "Building ${IMG_GLPI_APP}..."
      run_podman "build -t ${IMG_GLPI_APP} \
        --build-arg GLPI_VERSION=${GLPI_VERSION} \
        --build-arg IMG_PHP=${IMG_PHP} \
        -f ${GLPI_BASE}/Dockerfile.glpi ${GLPI_BASE}/"
      ok "Image built successfully."
    fi
  fi
else
  warn "--skip-build set. Using existing image or defaulting to ${IMG_GLPI_APP}."
fi

# ── Section 12: Start stack ───────────────────────────────────────────────────
section "12. Start container stack"

stack_up

# ── Section 13: DB initialization ─────────────────────────────────────────────
section "13. Initialize GLPI database"

if [[ $SKIP_DB -eq 1 ]]; then
  warn "--skip-db set. Skipping db:install."
else
  [[ $DRY_RUN -eq 0 ]] && {
    info "Waiting for glpi-db to be healthy..."
    wait_container_status glpi-db running 60 2 || { run_podman "logs glpi-db --tail 50"; die "glpi-db failed to start"; }

    for _ in $(seq 1 60); do
      s="$(run_podman "inspect glpi-db --format '{{.State.Health.Status}}'" 2>/dev/null || echo none)"
      [[ "$s" == "healthy" ]] && break
      sleep 2
    done

    TABLE_COUNT="$(run_podman "exec glpi-db mysql -u${MARIADB_USER} -p${DB_PW} ${MARIADB_DATABASE} \
      -e 'SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=\"${MARIADB_DATABASE}\";' \
      --skip-column-names 2>/dev/null" || echo 0)"
    TABLE_COUNT="${TABLE_COUNT//[^0-9]/}"

    if [[ "${TABLE_COUNT:-0}" -lt 100 ]]; then
      info "Running db:install..."
      run_podman "exec glpi-app php /srv/glpi-webroot/bin/console db:install \
        --db-host=glpi-db --db-port=3306 --db-name=${MARIADB_DATABASE} \
        --db-user=${MARIADB_USER} --db-password=${DB_PW} --no-interaction"
      ok "Database initialized."
    else
      ok "Database already initialized (${TABLE_COUNT} tables)."
    fi
  }
fi

# ── Section 14: Final checks ──────────────────────────────────────────────────
section "14. Final health checks"

[[ $DRY_RUN -eq 0 ]] && {
  info "Checking container status..."
  for ctr in glpi-db glpi-app glpi-nginx; do
    status="$(run_podman "inspect ${ctr} --format '{{.State.Health.Status}}'" 2>/dev/null || echo unknown)"
    ok "${ctr}: ${status}"
  done

  info "Testing HTTPS access..."
  code="$(curl -sk -o /dev/null -w "%{http_code}" https://127.0.0.1:${NGINX_HTTPS_PORT}/ 2>/dev/null || echo 000)"
  if [[ "$code" =~ ^(200|301|302|403)$ ]]; then
    ok "HTTPS returned ${code}"
  else
    warn "HTTPS returned ${code} — may still be starting up"
  fi
}

# ── Summary ───────────────────────────────────────────────────────────────────
section "Complete!"

cat <<NOTES

  GLPI is up and running.

  Access via:  https://${GLPI_HOSTNAME}:${NGINX_HTTPS_PORT}/
  Default:     glpi / glpi  (CHANGE IMMEDIATELY)

  View containers:
    podman-glpi ps
    podman-glpi logs glpi-app --tail 50

  Configure post-install:
    • Change default passwords (Setup > Users)
    • Configure SMTP (Setup > Notifications)
    • Configure LDAP if needed (Setup > Authentication)
    • Configure Zabbix if needed (Setup > General)

  See SETUP.md and CHECK.md for full documentation.

NOTES
