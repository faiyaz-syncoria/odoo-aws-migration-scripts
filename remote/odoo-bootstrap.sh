#!/usr/bin/env bash
# =============================================================================
# remote/odoo-bootstrap.sh  -  runs ON the EC2 box (as root), driven by
# /etc/odoo-migration.env uploaded by 02-deploy-odoo.sh.
#
# Installs a clean, production-shaped Odoo 18 Enterprise + local PostgreSQL,
# with the 1000GB EBS data volume mounted at /var/lib/odoo (durable filestore).
# Safe to re-run.
# =============================================================================
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

[[ -f /etc/odoo-migration.env ]] || { echo "missing /etc/odoo-migration.env"; exit 1; }
# shellcheck disable=SC1091
source /etc/odoo-migration.env

log(){ echo "[bootstrap] $*"; }

# -----------------------------------------------------------------------------
# 1. Mount the dedicated data volume at /var/lib/odoo (survives instance replace)
# -----------------------------------------------------------------------------
log "Locating data volume (~1000GB, unmounted)"
if mountpoint -q /var/lib/odoo; then
  log "Data volume already mounted at /var/lib/odoo ($(df -h --output=size /var/lib/odoo | tail -1 | tr -d ' ')) - skipping"
fi
DATA_DEV=""
while read -r name _ type mnt; do
  [[ "${type}" == "disk" ]] || continue
  [[ -n "${mnt}" ]] && continue                       # skip mounted disks
  # skip the root disk (the one carrying '/')
  root_disk="$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" 2>/dev/null || true)"
  [[ "${name}" == "${root_disk}" ]] && continue
  DATA_DEV="/dev/${name}"
done < <(lsblk -rno NAME,SIZE,TYPE,MOUNTPOINT)

if [[ -n "${DATA_DEV}" ]]; then
  log "Data device: ${DATA_DEV}"
  if ! blkid "${DATA_DEV}" >/dev/null 2>&1; then
    log "Formatting ${DATA_DEV} ext4"
    mkfs.ext4 -F -L odoo-data "${DATA_DEV}"
  fi
  mkdir -p /var/lib/odoo
  UUID="$(blkid -s UUID -o value "${DATA_DEV}")"
  if ! grep -q "${UUID}" /etc/fstab; then
    echo "UUID=${UUID}  /var/lib/odoo  ext4  defaults,nofail  0  2" >> /etc/fstab
  fi
  mountpoint -q /var/lib/odoo || mount /var/lib/odoo
  log "Mounted ${DATA_DEV} at /var/lib/odoo"
else
  log "No separate data volume found - using root disk for /var/lib/odoo"
  mkdir -p /var/lib/odoo
fi

# -----------------------------------------------------------------------------
# 2. Base OS packages + wkhtmltopdf (patched Qt build for PDF reports)
# -----------------------------------------------------------------------------
log "Installing base packages"
apt-get -o DPkg::Lock::Timeout=300 update -qq
apt-get -o DPkg::Lock::Timeout=300 install -y -qq \
  ca-certificates curl wget gnupg lsb-release git build-essential \
  software-properties-common \
  python3 python3-pip python3-dev python3-venv \
  libpq-dev libxml2-dev libxslt1-dev libldap2-dev libsasl2-dev libtiff5-dev \
  libjpeg8-dev libopenjp2-7-dev zlib1g-dev libfreetype6-dev liblcms2-dev \
  libwebp-dev libharfbuzz-dev libfribidi-dev libxcb1-dev fontconfig \
  node-less npm postgresql-client >/dev/null

# -----------------------------------------------------------------------------
# 2b. Python 3.12 (Odoo 18 target). Ubuntu 22.04 ships 3.10, whose pinned deps
#     (gevent, greenlet) build from source and fail against modern Cython.
#     On 3.12 those deps resolve to versions with prebuilt wheels -> no compile.
# -----------------------------------------------------------------------------
PYBIN="python3.12"
if ! command -v "${PYBIN}" >/dev/null 2>&1; then
  log "Installing Python 3.12 (deadsnakes PPA)"
  add-apt-repository -y ppa:deadsnakes/ppa >/dev/null 2>&1
  apt-get -o DPkg::Lock::Timeout=300 update -qq
  apt-get -o DPkg::Lock::Timeout=300 install -y -qq python3.12 python3.12-venv python3.12-dev >/dev/null
fi
log "Using $(${PYBIN} --version) for the Odoo virtualenv"

if ! command -v wkhtmltopdf >/dev/null 2>&1; then
  log "Installing wkhtmltopdf 0.12.6 (patched Qt)"
  ARCH="$(dpkg --print-architecture)"
  WK_DEB="wkhtmltox_0.12.6.1-2.jammy_${ARCH}.deb"
  wget -q "https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/${WK_DEB}" -O "/tmp/${WK_DEB}"
  apt-get -o DPkg::Lock::Timeout=300 install -y -qq "/tmp/${WK_DEB}" >/dev/null || apt-get -o DPkg::Lock::Timeout=300 -f install -y -qq >/dev/null
  rm -f "/tmp/${WK_DEB}"
fi

# -----------------------------------------------------------------------------
# 3. PostgreSQL (local, on the same box) + odoo role
# -----------------------------------------------------------------------------
if ! command -v psql >/dev/null 2>&1 || ! systemctl list-unit-files | grep -q '^postgresql'; then
  log "Installing PostgreSQL ${PG_VERSION}"
  install -d /usr/share/postgresql-common/pgdg
  curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
  echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] \
https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
    > /etc/apt/sources.list.d/pgdg.list
  apt-get -o DPkg::Lock::Timeout=300 update -qq
  apt-get -o DPkg::Lock::Timeout=300 install -y -qq "postgresql-${PG_VERSION}" >/dev/null
fi
systemctl enable --now postgresql

# pgvector: required by Odoo 19+'s built-in 'ai' module (ai_embedding.embedding_vector
# is a `vector(1536)` column). Same PGDG repo as postgresql-${PG_VERSION} above, so no
# extra repo setup needed. Without this, any `-u ai` (or full registry load touching
# the ai module) fails with "type \"vector\" does not exist".
if ! dpkg -s "postgresql-${PG_VERSION}-pgvector" >/dev/null 2>&1; then
  log "Installing pgvector for PostgreSQL ${PG_VERSION}"
  apt-get -o DPkg::Lock::Timeout=300 install -y -qq "postgresql-${PG_VERSION}-pgvector" >/dev/null
fi

log "Ensuring PostgreSQL role '${PG_ODOO_DB_USER}'"
sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${PG_ODOO_DB_USER}'" | grep -q 1 || \
  sudo -u postgres psql -c "CREATE ROLE ${PG_ODOO_DB_USER} LOGIN CREATEDB PASSWORD '${PG_ODOO_DB_PASSWORD}';"
sudo -u postgres psql -c "ALTER ROLE ${PG_ODOO_DB_USER} PASSWORD '${PG_ODOO_DB_PASSWORD}';" >/dev/null

# -----------------------------------------------------------------------------
# 4. System user + directories
# -----------------------------------------------------------------------------
id "${ODOO_USER}" >/dev/null 2>&1 || useradd -m -d "${ODOO_HOME}" -U -r -s /bin/bash "${ODOO_USER}"
mkdir -p "${ODOO_HOME}" "${ODOO_CUSTOM_ADDONS}" "$(dirname "${ODOO_CONF}")" \
         /var/log/odoo "${ODOO_HOME}/backups" "${ODOO_FILESTORE}"
chown -R "${ODOO_USER}:${ODOO_USER}" "${ODOO_HOME}" /var/lib/odoo /var/log/odoo

# -----------------------------------------------------------------------------
# 5. Odoo 18 source: community core (git, pinned to 18.0) + Enterprise addons
# -----------------------------------------------------------------------------
clone_or_update() { # url dest [auth]
  local url="$1" dest="$2"
  if [[ -d "${dest}/.git" ]]; then
    log "Updating $(basename "${dest}")"
    git -C "${dest}" fetch --depth 1 origin "${ODOO_VERSION}" && \
    git -C "${dest}" reset --hard "origin/${ODOO_VERSION}"
  else
    log "Cloning $(basename "${dest}") (${ODOO_VERSION})"
    git clone --depth 1 --branch "${ODOO_VERSION}" "${url}" "${dest}"
  fi
}

sudo -u "${ODOO_USER}" -H bash <<EOSU
set -Eeuo pipefail
export ODOO_VERSION="${ODOO_VERSION}"
# community core - reset to FETCH_HEAD so switching versions (e.g. 18.0 -> 19.0)
# works even on a shallow single-branch clone that has no origin/<ver> ref.
if [[ -d "${ODOO_HOME}/odoo/.git" ]]; then
  git -C "${ODOO_HOME}/odoo" fetch --depth 1 origin "${ODOO_VERSION}" && git -C "${ODOO_HOME}/odoo" reset --hard FETCH_HEAD
else
  git clone --depth 1 --branch "${ODOO_VERSION}" https://github.com/odoo/odoo.git "${ODOO_HOME}/odoo"
fi
# enterprise addons (private repo -> token auth)
ENT_URL="https://${GITHUB_USER}:${GITHUB_TOKEN}@github.com/odoo/enterprise.git"
if [[ -d "${ODOO_ENTERPRISE_ADDONS}/.git" ]]; then
  git -C "${ODOO_ENTERPRISE_ADDONS}" remote set-url origin "\${ENT_URL}"
  git -C "${ODOO_ENTERPRISE_ADDONS}" fetch --depth 1 origin "${ODOO_VERSION}" && git -C "${ODOO_ENTERPRISE_ADDONS}" reset --hard FETCH_HEAD
else
  git clone --depth 1 --branch "${ODOO_VERSION}" "\${ENT_URL}" "${ODOO_ENTERPRISE_ADDONS}"
fi
# scrub token from git config so it is not left on disk
git -C "${ODOO_ENTERPRISE_ADDONS}" remote set-url origin "${ODOO_ENTERPRISE_GIT}"
EOSU

# -----------------------------------------------------------------------------
# 6. Python virtualenv + Odoo requirements
# -----------------------------------------------------------------------------
# (Re)create the venv on Python 3.12. If a venv from a previous run exists on a
# different Python (e.g. the failed 3.10 attempt), drop and rebuild it.
VENV_OK="no"
if [[ -x "${ODOO_HOME}/venv/bin/python" ]]; then
  cur="$("${ODOO_HOME}/venv/bin/python" -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null || echo '?')"
  [[ "${cur}" == "3.12" ]] && VENV_OK="yes" || { log "Existing venv is Python ${cur}; rebuilding on 3.12"; rm -rf "${ODOO_HOME}/venv"; }
fi
if [[ "${VENV_OK}" != "yes" ]]; then
  log "Creating Python 3.12 virtualenv"
  sudo -u "${ODOO_USER}" "${PYBIN}" -m venv "${ODOO_HOME}/venv"
fi
log "Installing Python requirements (this can take a few minutes)"
sudo -u "${ODOO_USER}" "${ODOO_HOME}/venv/bin/pip" install --quiet --upgrade pip wheel setuptools
sudo -u "${ODOO_USER}" "${ODOO_HOME}/venv/bin/pip" install --quiet -r "${ODOO_HOME}/odoo/requirements.txt"

# -----------------------------------------------------------------------------
# 7. odoo.conf
# -----------------------------------------------------------------------------
log "Writing ${ODOO_CONF}"
cat > "${ODOO_CONF}" <<EOF
[options]
admin_passwd = ${ODOO_ADMIN_PASSWD}
db_host = 127.0.0.1
db_port = 5432
db_user = ${PG_ODOO_DB_USER}
db_password = ${PG_ODOO_DB_PASSWORD}
addons_path = ${ODOO_ENTERPRISE_ADDONS},${ODOO_HOME}/odoo/addons,${ODOO_CUSTOM_ADDONS}
data_dir = /var/lib/odoo
logfile = /var/log/odoo/odoo.log
proxy_mode = True
; worker/tuning values are set by 04-harden-and-tune.sh based on instance size
workers = 0
max_cron_threads = 1
EOF
chown "${ODOO_USER}:${ODOO_USER}" "${ODOO_CONF}"
chmod 640 "${ODOO_CONF}"

# -----------------------------------------------------------------------------
# 8. systemd unit
# -----------------------------------------------------------------------------
log "Writing systemd unit"
cat > /etc/systemd/system/odoo.service <<EOF
[Unit]
Description=Odoo ${ODOO_VERSION} (${ODOO_ENV})
After=network.target postgresql.service
Requires=postgresql.service

[Service]
Type=simple
User=${ODOO_USER}
Group=${ODOO_USER}
ExecStart=${ODOO_HOME}/venv/bin/python3 ${ODOO_HOME}/odoo/odoo-bin -c ${ODOO_CONF}
KillMode=mixed
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable odoo
systemctl restart odoo
sleep 8
systemctl --no-pager --full status odoo | head -n 12 || true

log "Bootstrap complete for ${ODOO_ENV}"
