#!/usr/bin/env bash
# =============================================================================
# lib/common.sh  -  shared helpers sourced by every migration script.
# Provides: strict mode, logging, config loading, secret handling, idempotency
# helpers, AWS lookup helpers, and remote-exec helpers.
# =============================================================================

# ---- strict mode ------------------------------------------------------------
set -Eeuo pipefail
IFS=$'\n\t'

# ---- resolve repo root (dir that contains config.env) -----------------------
# Works regardless of the directory the caller invokes from.
COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${COMMON_DIR}/.." && pwd)"
SECRETS_DIR="${REPO_ROOT}/secrets"
STATE_DIR="${REPO_ROOT}/.state"
LOG_DIR="${REPO_ROOT}/logs"
mkdir -p "${SECRETS_DIR}" "${STATE_DIR}" "${LOG_DIR}"
chmod 700 "${SECRETS_DIR}"

# ---- colours / logging ------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GRN=$'\033[32m'
  C_YEL=$'\033[33m'; C_BLU=$'\033[34m'; C_BOLD=$'\033[1m'
else
  C_RESET=""; C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_BOLD=""
fi

_ts() { date +'%Y-%m-%d %H:%M:%S'; }
log()   { echo "${C_BLU}[$(_ts)]${C_RESET} $*"; }
info()  { echo "${C_BLU}[$(_ts)] INFO ${C_RESET} $*"; }
ok()    { echo "${C_GRN}[$(_ts)] OK   ${C_RESET} $*"; }
warn()  { echo "${C_YEL}[$(_ts)] WARN ${C_RESET} $*" >&2; }
err()   { echo "${C_RED}[$(_ts)] ERROR${C_RESET} $*" >&2; }
die()   { err "$*"; exit 1; }

# banner for a major checkpoint
checkpoint() {
  echo
  echo "${C_BOLD}${C_GRN}==============================================================${C_RESET}"
  echo "${C_BOLD}${C_GRN}  CHECKPOINT: $*${C_RESET}"
  echo "${C_BOLD}${C_GRN}==============================================================${C_RESET}"
  echo
}

# error trap - shows the failing line for fast diagnosis
_on_err() {
  local ec=$?
  err "Failed (exit ${ec}) at ${BASH_SOURCE[1]:-?}:${BASH_LINENO[0]:-?} : ${BASH_COMMAND}"
  exit "${ec}"
}
trap _on_err ERR

# ---- config loading ---------------------------------------------------------
load_config() {
  local cfg="${REPO_ROOT}/config.env"
  [[ -f "${cfg}" ]] || die "config.env not found. Run: cp config.env.example config.env  and edit it."
  # shellcheck disable=SC1090
  source "${cfg}"
  : "${PROJECT_NAME:?PROJECT_NAME missing in config.env}"
  : "${AWS_REGION:?AWS_REGION missing in config.env}"
  export AWS_DEFAULT_REGION="${AWS_REGION}"
  if [[ -n "${AWS_PROFILE:-}" ]]; then export AWS_PROFILE; fi
  return 0
}

# fail loudly if any <CHANGE_ME...> placeholders remain in the vars we need
require_no_placeholder() {
  local name val
  for name in "$@"; do
    val="${!name:-}"
    if [[ -z "${val}" ]]; then die "Config ${name} is empty."; fi
    if [[ "${val}" == *CHANGE_ME* ]]; then die "Config ${name} still holds a placeholder: ${val}"; fi
  done
  return 0
}

# ---- secrets ----------------------------------------------------------------
# gen_secret <length>  -> url-safe random string
gen_secret() { openssl rand -base64 "${1:-24}" | tr -d '/+=' | cut -c1-"${1:-24}"; }

# resolve_secret VARNAME FILE  : if $VARNAME == AUTO, generate, persist to FILE.
# echoes the resolved value.
resolve_secret() {
  local varname="$1" file="${SECRETS_DIR}/$2"
  local val="${!varname:-}"
  if [[ "${val}" == "AUTO" ]]; then
    if [[ -f "${file}" ]]; then val="$(cat "${file}")"; else
      val="$(gen_secret 30)"; umask 077; printf '%s' "${val}" > "${file}"
    fi
  fi
  printf '%s' "${val}"
}

# ---- idempotency state ------------------------------------------------------
# Values discovered during provisioning (VPC id, instance ids, IPs...) are
# written to .state/<env>.env so later scripts can consume them.
state_file() { echo "${STATE_DIR}/${1}.env"; }

state_set() { # env key value
  local f; f="$(state_file "$1")"; touch "${f}"
  grep -v "^${2}=" "${f}" > "${f}.tmp" 2>/dev/null || true
  echo "${2}=${3}" >> "${f}.tmp"; mv "${f}.tmp" "${f}"
}
state_get() { # env key
  local f; f="$(state_file "$1")"
  [[ -f "${f}" ]] && (grep "^${2}=" "${f}" | tail -1 | cut -d= -f2-) || true
}
state_load() { # env  -> sources all keys into environment
  local f; f="$(state_file "$1")"; [[ -f "${f}" ]] && source "${f}" || true
}

# ---- prerequisite checks ----------------------------------------------------
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

check_aws_auth() {
  need_cmd aws
  aws sts get-caller-identity >/dev/null 2>&1 \
    || die "AWS CLI is not authenticated for profile '${AWS_PROFILE:-default}'. Run 'aws configure'."
  if [[ -n "${AWS_ACCOUNT_ID:-}" && "${AWS_ACCOUNT_ID}" != *CHANGE_ME* ]]; then
    local live_acct
    live_acct="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
    [[ "${live_acct}" == "${AWS_ACCOUNT_ID}" ]] \
      || die "Authenticated AWS account (${live_acct}) does not match config.env AWS_ACCOUNT_ID (${AWS_ACCOUNT_ID}) - wrong profile/account, refusing to proceed."
  fi
}

# ---- per-environment spec resolver -----------------------------------------
# Sets ENV_* variables for the given environment name.
resolve_env_spec() {
  local e="$1" up
  up="$(echo "${e}" | tr '[:lower:]' '[:upper:]')"
  ENV_NAME="${e}"
  ENV_INSTANCE_TYPE="$(eval echo "\${${up}_INSTANCE_TYPE}")"
  ENV_EBS_GB="$(eval echo "\${${up}_EBS_GB}")"
  ENV_MONITORING="$(eval echo "\${${up}_MONITORING}")"
  ENV_TENANCY="$(eval echo "\${${up}_TENANCY}")"
  ENV_DOMAIN="$(eval echo "\${${up}_DOMAIN}")"
  export ENV_NAME ENV_INSTANCE_TYPE ENV_EBS_GB ENV_MONITORING ENV_TENANCY ENV_DOMAIN
}

# ---- AWS lookup helpers (idempotency by Name tag) ---------------------------
tag_name() { echo "${PROJECT_NAME}-$1"; }   # e.g. tag_name production -> syncoria-odoo-production

aws_vpc_id() {
  aws ec2 describe-vpcs \
    --filters "Name=tag:Name,Values=$(tag_name vpc)" "Name=state,Values=available" \
    --query 'Vpcs[0].VpcId' --output text 2>/dev/null | grep -v '^None$' || true
}
aws_instance_id() { # env
  aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$(tag_name "$1")" \
              "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null \
    | grep -v '^None$' || true
}
aws_instance_public_ip() { # instance-id
  aws ec2 describe-instances --instance-ids "$1" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text 2>/dev/null \
    | grep -v '^None$' || true
}

# ---- optional S3 backup infra (bucket + lifecycle + IAM role/profile) ------
# No-op if BACKUP_S3_BUCKET is unset. Idempotent: bucket/role/policy/profile
# are matched by name, so re-running just reconciles (e.g. picks up a changed
# BACKUP_RETENTION_DAYS into the lifecycle rule). Called once per run (bucket
# + role/policy/profile are shared across environments); each environment's
# instance still needs the profile attached separately via
# ensure_backup_profile_attached.
ensure_backup_s3_infra() {
  [[ -n "${BACKUP_S3_BUCKET:-}" ]] || return 0
  check_aws_auth

  if aws s3api head-bucket --bucket "${BACKUP_S3_BUCKET}" 2>/dev/null; then
    info "S3 bucket ${BACKUP_S3_BUCKET} already exists"
  else
    info "Creating S3 bucket ${BACKUP_S3_BUCKET} for backups"
    if [[ "${AWS_REGION}" == "us-east-1" ]]; then
      aws s3api create-bucket --bucket "${BACKUP_S3_BUCKET}" --region "${AWS_REGION}"
    else
      aws s3api create-bucket --bucket "${BACKUP_S3_BUCKET}" --region "${AWS_REGION}" \
        --create-bucket-configuration LocationConstraint="${AWS_REGION}"
    fi
    aws s3api put-public-access-block --bucket "${BACKUP_S3_BUCKET}" \
      --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
    aws s3api put-bucket-encryption --bucket "${BACKUP_S3_BUCKET}" \
      --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
  fi

  info "Ensuring S3 lifecycle rule (expire after ${BACKUP_RETENTION_DAYS}d) on ${BACKUP_S3_BUCKET}"
  aws s3api put-bucket-lifecycle-configuration --bucket "${BACKUP_S3_BUCKET}" \
    --lifecycle-configuration "{\"Rules\":[{\"ID\":\"expire-backups\",\"Filter\":{},\"Status\":\"Enabled\",\"Expiration\":{\"Days\":${BACKUP_RETENTION_DAYS}}}]}"

  local role policy profile trust perm
  role="$(tag_name backup-role)"; profile="$(tag_name backup-profile)"; policy="$(tag_name backup-s3-policy)"
  trust='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
  perm="{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"s3:PutObject\",\"s3:GetObject\",\"s3:ListBucket\"],\"Resource\":[\"arn:aws:s3:::${BACKUP_S3_BUCKET}\",\"arn:aws:s3:::${BACKUP_S3_BUCKET}/*\"]}]}"

  if aws iam get-role --role-name "${role}" >/dev/null 2>&1; then
    info "IAM role ${role} already exists"
  else
    info "Creating IAM role ${role} (S3 backup access, scoped to ${BACKUP_S3_BUCKET})"
    aws iam create-role --role-name "${role}" --assume-role-policy-document "${trust}" \
      --tags "Key=Name,Value=${role}" >/dev/null \
      || die "Could not create IAM role ${role}. IAM write actions (CreateRole etc.) are sometimes walled off even under broad EC2 admin roles - grant temporary elevated IAM access, or create the role/policy/instance-profile yourself (see CLAUDE.md 'IAM write actions' gotcha), then re-run."
  fi
  aws iam put-role-policy --role-name "${role}" --policy-name "${policy}" --policy-document "${perm}" >/dev/null

  if aws iam get-instance-profile --instance-profile-name "${profile}" >/dev/null 2>&1; then
    info "IAM instance profile ${profile} already exists"
  else
    aws iam create-instance-profile --instance-profile-name "${profile}" >/dev/null
    aws iam add-role-to-instance-profile --instance-profile-name "${profile}" --role-name "${role}"
  fi
}

# Ensure an environment's EC2 instance has the shared backup instance profile
# attached (idempotent - no-ops if already correct; replaces a different
# association if one exists). No-op if BACKUP_S3_BUCKET is unset.
ensure_backup_profile_attached() { # instance-id
  [[ -n "${BACKUP_S3_BUCKET:-}" ]] || return 0
  local instance_id="$1" profile
  profile="$(tag_name backup-profile)"
  local assoc_json assoc_id assoc_name
  assoc_json="$(aws ec2 describe-iam-instance-profile-associations \
    --filters "Name=instance-id,Values=${instance_id}" "Name=state,Values=associating,associated" \
    --query 'IamInstanceProfileAssociations[0]' --output json 2>/dev/null)"
  assoc_id="$(echo "${assoc_json}" | jq -r '.AssociationId // empty')"
  assoc_name="$(echo "${assoc_json}" | jq -r '.IamInstanceProfile.Arn // empty' | sed 's#.*/##')"
  if [[ "${assoc_name}" == "${profile}" ]]; then
    info "Instance ${instance_id} already has instance profile ${profile}"
  elif [[ -n "${assoc_id}" ]]; then
    info "Replacing instance profile on ${instance_id} (${assoc_name:-none} -> ${profile})"
    aws ec2 replace-iam-instance-profile-association --association-id "${assoc_id}" \
      --iam-instance-profile "Name=${profile}" >/dev/null
  else
    info "Attaching instance profile ${profile} to ${instance_id}"
    # A profile created moments ago by ensure_backup_s3_infra may not have
    # propagated to the EC2 control plane yet - IAM is eventually consistent,
    # and EC2 rejects an unpropagated name with "Invalid IAM Instance Profile
    # name" (not a permissions error, just a race). Retry briefly.
    local attempt
    for attempt in 1 2 3 4 5; do
      if aws ec2 associate-iam-instance-profile --instance-id "${instance_id}" \
          --iam-instance-profile "Name=${profile}" >/dev/null 2>/tmp/assoc-err.$$; then
        rm -f /tmp/assoc-err.$$
        return 0
      fi
      if grep -q "Invalid IAM Instance Profile name" /tmp/assoc-err.$$ && [[ "${attempt}" -lt 5 ]]; then
        warn "Instance profile ${profile} not yet visible to EC2 (IAM propagation delay) - retrying in 5s (${attempt}/5)"
        sleep 5
      else
        cat /tmp/assoc-err.$$ >&2; rm -f /tmp/assoc-err.$$
        die "Could not attach instance profile ${profile} to ${instance_id}"
      fi
    done
  fi
}

# ---- remote exec helpers ----------------------------------------------------
# Run a local script on a remote box over SSH.
ssh_key_path() { echo "${SECRETS_DIR}/${EC2_KEY_NAME}.pem"; }

remote_ssh() { # host  command...
  local host="$1"; shift
  # ServerAlive*: long-running silent remote commands (e.g. the restore's
  # multi-hour filestore tar/DB load) can otherwise get dropped by an idle
  # NAT/firewall between here and AWS - see CLAUDE.md's 'long-silent SSH
  # command' gotcha.
  ssh -i "$(ssh_key_path)" -o StrictHostKeyChecking=accept-new \
      -o ConnectTimeout=15 -o ServerAliveInterval=30 -o ServerAliveCountMax=10 \
      "${SSH_USER}@${host}" "$@"
}
remote_copy() { # src  host:dest
  local src="$1" dest="$2"
  scp -i "$(ssh_key_path)" -o StrictHostKeyChecking=accept-new -q "${src}" "${SSH_USER}@${dest}"
}
# Copy a script up and run it with sudo, streaming output back.
remote_run_script() { # host  local_script  [args...]
  local host="$1" script="$2"; shift 2
  local base; base="$(basename "${script}")"
  remote_copy "${script}" "${host}:/tmp/${base}"
  remote_ssh "${host}" "chmod +x /tmp/${base} && sudo /tmp/${base} $*"
}

# wait until SSH is answering on a host
wait_for_ssh() { # host
  local host="$1" tries=40
  info "Waiting for SSH on ${host} ..."
  until remote_ssh "${host}" true 2>/dev/null; do
    ((tries--)) || die "SSH never came up on ${host}"
    sleep 10
  done
  ok "SSH is up on ${host}"
}

# confirm() prompt   -> returns 0 if user types yes (skipped when ASSUME_YES=1)
confirm() {
  [[ "${ASSUME_YES:-0}" == "1" ]] && return 0
  read -r -p "$1 [y/N] " ans
  [[ "${ans}" =~ ^([yY]|yes)$ ]]
}
