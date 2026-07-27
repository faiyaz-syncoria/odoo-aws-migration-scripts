#!/usr/bin/env bash
# =============================================================================
# restrict-web-to-cloudflare.sh
# -----------------------------------------------------------------------------
# When the site is proxied through Cloudflare, no one should be able to reach the
# origin's 80/443 directly (that would bypass the WAF/proxy). This locks the
# security group's HTTP/HTTPS ingress to Cloudflare's published IP ranges.
#
# SSH (22) is NOT touched - keep managing it with update-my-ip.sh.
#
# Run this only AFTER you've confirmed the site works through Cloudflare, so a
# misconfiguration can't cut off your only web path. Re-run any time to refresh
# the ranges (Cloudflare changes them rarely).
#
# Usage:  ./restrict-web-to-cloudflare.sh          (apply)
#         ./restrict-web-to-cloudflare.sh --open   (revert to 0.0.0.0/0)
# =============================================================================
source "$(dirname "$0")/lib/common.sh"
load_config
check_aws_auth

VPC_ID="$(aws_vpc_id)"; [[ -n "${VPC_ID}" ]] || die "No project VPC found - run 01 first."
SG_ID="$(aws ec2 describe-security-groups \
  --filters "Name=tag:Name,Values=$(tag_name sg)" "Name=vpc-id,Values=${VPC_ID}" \
  --query 'SecurityGroups[0].GroupId' --output text | grep -v '^None$' || true)"
[[ -n "${SG_ID}" ]] || die "Security group $(tag_name sg) not found."

revoke_port() { # port
  local port="$1" cidrs c
  cidrs="$(aws ec2 describe-security-groups --group-ids "${SG_ID}" \
    --query "SecurityGroups[0].IpPermissions[?FromPort==\`${port}\`].IpRanges[].CidrIp" --output text 2>/dev/null || true)"
  for c in ${cidrs}; do
    aws ec2 revoke-security-group-ingress --group-id "${SG_ID}" --protocol tcp --port "${port}" --cidr "${c}" >/dev/null 2>&1 || true
  done
  # also drop any existing IPv6 rules on this port
  local v6; v6="$(aws ec2 describe-security-groups --group-ids "${SG_ID}" \
    --query "SecurityGroups[0].IpPermissions[?FromPort==\`${port}\`].Ipv6Ranges[].CidrIpv6" --output text 2>/dev/null || true)"
  for c in ${v6}; do
    aws ec2 revoke-security-group-ingress --group-id "${SG_ID}" \
      --ip-permissions "IpProtocol=tcp,FromPort=${port},ToPort=${port},Ipv6Ranges=[{CidrIpv6=${c}}]" >/dev/null 2>&1 || true
  done
}

if [[ "${1:-}" == "--open" ]]; then
  checkpoint "Reverting: open 80/443 to the world"
  for p in 80 443; do
    revoke_port "${p}"
    aws ec2 authorize-security-group-ingress --group-id "${SG_ID}" --protocol tcp --port "${p}" --cidr 0.0.0.0/0 >/dev/null 2>&1 || true
  done
  ok "80/443 now open to 0.0.0.0/0 on ${SG_ID}"
  exit 0
fi

checkpoint "Locking origin 80/443 to Cloudflare IP ranges (${SG_ID})"
info "Fetching current Cloudflare IP ranges"
V4="$(curl -fsS https://www.cloudflare.com/ips-v4 2>/dev/null || true)"
V6="$(curl -fsS https://www.cloudflare.com/ips-v6 2>/dev/null || true)"
[[ -n "${V4}" ]] || die "Could not fetch Cloudflare IPv4 ranges (https://www.cloudflare.com/ips-v4)"

for p in 80 443; do
  info "Port ${p}: clearing existing rules, adding Cloudflare ranges"
  revoke_port "${p}"
  while read -r cidr; do
    [[ -z "${cidr}" ]] && continue
    aws ec2 authorize-security-group-ingress --group-id "${SG_ID}" --protocol tcp --port "${p}" --cidr "${cidr}" >/dev/null 2>&1 || true
  done <<< "${V4}"
  while read -r cidr; do
    [[ -z "${cidr}" ]] && continue
    aws ec2 authorize-security-group-ingress --group-id "${SG_ID}" \
      --ip-permissions "IpProtocol=tcp,FromPort=${p},ToPort=${p},Ipv6Ranges=[{CidrIpv6=${cidr}}]" >/dev/null 2>&1 || true
  done <<< "${V6}"
done

ok "Origin 80/443 now accept traffic only from Cloudflare on ${SG_ID}."
info "Direct-to-IP web access is now blocked (SSH on 22 is unaffected)."
info "Revert with: ./restrict-web-to-cloudflare.sh --open"
