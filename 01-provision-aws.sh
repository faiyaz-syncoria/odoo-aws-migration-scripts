#!/usr/bin/env bash
# =============================================================================
# 01-provision-aws.sh  -  CHECKPOINT 1: AWS provisioning (Production + Staging)
# -----------------------------------------------------------------------------
# Creates, idempotently, using ONLY the AWS CLI:
#   - one shared VPC + public subnet + IGW + route table   (project scope)
#   - a per-purpose security group (SSH/HTTP/HTTPS)
#   - an EC2 key pair (private key saved to ./secrets)
#   - one EC2 instance per environment with the exact brief spec:
#       production : t3.large,  detailed monitoring ON,  1000GB gp3, Elastic IP
#       staging    : t3.medium, detailed monitoring OFF, 1000GB gp3, Elastic IP
#   - tags every resource for cost allocation and later lookup
#
# Re-running is safe: existing resources (matched by Name tag) are reused.
#
# Usage:
#   ./01-provision-aws.sh                # both environments
#   ./01-provision-aws.sh production     # single environment
# =============================================================================
source "$(dirname "$0")/lib/common.sh"
load_config
check_aws_auth
require_no_placeholder ADMIN_ALLOWED_CIDR

TARGET_ENVS=("$@"); [[ ${#TARGET_ENVS[@]} -eq 0 ]] && TARGET_ENVS=("${ENVIRONMENTS[@]}")

# ---- resolve AMI ------------------------------------------------------------
# Prefer the SSM public parameter (needs ssm:GetParameters); fall back to
# describe-images against Canonical's account (needs only ec2:DescribeImages).
resolve_ami() {
  if [[ "${EC2_AMI_ID}" != "AUTO" ]]; then echo "${EC2_AMI_ID}"; return; fi
  local ami=""
  ami="$(aws ssm get-parameters \
    --names /aws/service/canonical/ubuntu/server/22.04/stable/current/amd64/hvm/ebs-gp2/ami-id \
    --query 'Parameters[0].Value' --output text 2>/dev/null | grep -E '^ami-' || true)"
  if [[ -z "${ami}" ]]; then
    # Canonical owner id 099720109477; newest Ubuntu 22.04 (jammy) amd64 server
    ami="$(aws ec2 describe-images --owners 099720109477 \
      --filters 'Name=name,Values=ubuntu/images/hvm-ssd*/ubuntu-jammy-22.04-amd64-server-*' \
                'Name=state,Values=available' 'Name=architecture,Values=x86_64' \
      --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text 2>/dev/null | grep -E '^ami-' || true)"
  fi
  [[ -n "${ami}" ]] || die "Could not resolve an Ubuntu 22.04 AMI (need ssm:GetParameters or ec2:DescribeImages)."
  echo "${ami}"
}

# =============================================================================
# STEP A - shared network (VPC / subnet / IGW / route table)
# =============================================================================
provision_network() {
  checkpoint "1A - Network (VPC / subnet / IGW)"

  VPC_ID="$(aws_vpc_id)"
  if [[ -z "${VPC_ID}" ]]; then
    info "Creating VPC ${VPC_CIDR}"
    VPC_ID="$(aws ec2 create-vpc --cidr-block "${VPC_CIDR}" \
      --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=$(tag_name vpc)},{Key=Project,Value=${PROJECT_NAME}}]" \
      --query 'Vpc.VpcId' --output text)"
    aws ec2 modify-vpc-attribute --vpc-id "${VPC_ID}" --enable-dns-hostnames
    aws ec2 modify-vpc-attribute --vpc-id "${VPC_ID}" --enable-dns-support
    ok "VPC ${VPC_ID} created"
  else
    ok "Reusing VPC ${VPC_ID}"
  fi

  # subnet
  SUBNET_ID="$(aws ec2 describe-subnets \
    --filters "Name=tag:Name,Values=$(tag_name subnet)" "Name=vpc-id,Values=${VPC_ID}" \
    --query 'Subnets[0].SubnetId' --output text | grep -v '^None$' || true)"
  if [[ -z "${SUBNET_ID}" ]]; then
    info "Creating subnet ${SUBNET_CIDR} in ${AWS_AZ}"
    SUBNET_ID="$(aws ec2 create-subnet --vpc-id "${VPC_ID}" \
      --cidr-block "${SUBNET_CIDR}" --availability-zone "${AWS_AZ}" \
      --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$(tag_name subnet)},{Key=Project,Value=${PROJECT_NAME}}]" \
      --query 'Subnet.SubnetId' --output text)"
    aws ec2 modify-subnet-attribute --subnet-id "${SUBNET_ID}" --map-public-ip-on-launch
    ok "Subnet ${SUBNET_ID} created"
  else
    ok "Reusing subnet ${SUBNET_ID}"
  fi

  # internet gateway
  IGW_ID="$(aws ec2 describe-internet-gateways \
    --filters "Name=tag:Name,Values=$(tag_name igw)" \
    --query 'InternetGateways[0].InternetGatewayId' --output text | grep -v '^None$' || true)"
  if [[ -z "${IGW_ID}" ]]; then
    IGW_ID="$(aws ec2 create-internet-gateway \
      --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=$(tag_name igw)},{Key=Project,Value=${PROJECT_NAME}}]" \
      --query 'InternetGateway.InternetGatewayId' --output text)"
    ok "IGW ${IGW_ID} created"
  else
    ok "Reusing IGW ${IGW_ID}"
  fi
  # attach if not attached
  if ! aws ec2 describe-internet-gateways --internet-gateway-ids "${IGW_ID}" \
        --query 'InternetGateways[0].Attachments[0].VpcId' --output text 2>/dev/null | grep -q "${VPC_ID}"; then
    aws ec2 attach-internet-gateway --internet-gateway-id "${IGW_ID}" --vpc-id "${VPC_ID}"
    ok "IGW attached to VPC"
  fi

  # route table + default route + association
  RT_ID="$(aws ec2 describe-route-tables \
    --filters "Name=tag:Name,Values=$(tag_name rt)" "Name=vpc-id,Values=${VPC_ID}" \
    --query 'RouteTables[0].RouteTableId' --output text | grep -v '^None$' || true)"
  if [[ -z "${RT_ID}" ]]; then
    RT_ID="$(aws ec2 create-route-table --vpc-id "${VPC_ID}" \
      --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=$(tag_name rt)},{Key=Project,Value=${PROJECT_NAME}}]" \
      --query 'RouteTable.RouteTableId' --output text)"
    ok "Route table ${RT_ID} created"
  else
    ok "Reusing route table ${RT_ID}"
  fi
  aws ec2 create-route --route-table-id "${RT_ID}" \
    --destination-cidr-block 0.0.0.0/0 --gateway-id "${IGW_ID}" >/dev/null 2>&1 || true
  aws ec2 associate-route-table --route-table-id "${RT_ID}" --subnet-id "${SUBNET_ID}" >/dev/null 2>&1 || true

  # persist shared network state (used by all envs)
  for e in "${ENVIRONMENTS[@]}"; do
    state_set "$e" VPC_ID "${VPC_ID}"
    state_set "$e" SUBNET_ID "${SUBNET_ID}"
  done
}

# =============================================================================
# STEP B - security group (one shared SG, least-privilege)
# =============================================================================
provision_security_group() {
  checkpoint "1B - Security group"
  SG_ID="$(aws ec2 describe-security-groups \
    --filters "Name=tag:Name,Values=$(tag_name sg)" "Name=vpc-id,Values=${VPC_ID}" \
    --query 'SecurityGroups[0].GroupId' --output text | grep -v '^None$' || true)"
  if [[ -z "${SG_ID}" ]]; then
    SG_ID="$(aws ec2 create-security-group --group-name "$(tag_name sg)" \
      --description "${PROJECT_NAME} odoo access" --vpc-id "${VPC_ID}" \
      --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$(tag_name sg)},{Key=Project,Value=${PROJECT_NAME}}]" \
      --query 'GroupId' --output text)"
    ok "Security group ${SG_ID} created"
  else
    ok "Reusing security group ${SG_ID}"
  fi
  # ingress rules (idempotent: ignore "already exists")
  authorize() { aws ec2 authorize-security-group-ingress --group-id "${SG_ID}" "$@" >/dev/null 2>&1 || true; }
  authorize --protocol tcp --port 22  --cidr "${ADMIN_ALLOWED_CIDR}"   # SSH (admin only)
  authorize --protocol tcp --port 80  --cidr "${WEB_ALLOWED_CIDR}"     # HTTP (redirect->HTTPS)
  authorize --protocol tcp --port 443 --cidr "${WEB_ALLOWED_CIDR}"     # HTTPS
  ok "Ingress: 22<-${ADMIN_ALLOWED_CIDR}, 80/443<-${WEB_ALLOWED_CIDR}"
  for e in "${ENVIRONMENTS[@]}"; do state_set "$e" SG_ID "${SG_ID}"; done
}

# =============================================================================
# STEP C - key pair
# =============================================================================
provision_keypair() {
  checkpoint "1C - EC2 key pair"
  if aws ec2 describe-key-pairs --key-names "${EC2_KEY_NAME}" >/dev/null 2>&1; then
    ok "Key pair ${EC2_KEY_NAME} already exists in AWS"
    [[ -f "$(ssh_key_path)" ]] || warn "Private key missing locally at $(ssh_key_path) - you need the original .pem to SSH."
  else
    info "Creating key pair ${EC2_KEY_NAME}"
    umask 077
    aws ec2 create-key-pair --key-name "${EC2_KEY_NAME}" \
      --query 'KeyMaterial' --output text > "$(ssh_key_path)"
    chmod 400 "$(ssh_key_path)"
    ok "Private key saved to $(ssh_key_path)"
  fi
}

# =============================================================================
# STEP D - per-environment EC2 instance + EBS + Elastic IP
# =============================================================================
provision_instance() {
  local e="$1"
  resolve_env_spec "${e}"
  state_load "${e}"
  checkpoint "1D - EC2 instance : ${e} (${ENV_INSTANCE_TYPE})"

  local iid; iid="$(aws_instance_id "${e}")"
  if [[ -n "${iid}" ]]; then
    ok "Instance for ${e} already exists: ${iid} (reusing)"
  else
    local ami mon_flag
    ami="$(resolve_ami)"
    info "Using AMI ${ami}"
    [[ "${ENV_MONITORING}" == "enabled" ]] && mon_flag="Enabled=true" || mon_flag="Enabled=false"

    # Root volume carries OS; a dedicated 1000GB gp3 data volume is defined via
    # block-device-mapping on /dev/sdf and mounted by 02-deploy-odoo.sh.
    local bdm
    bdm="$(cat <<JSON
[
  {"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":30,"VolumeType":"gp3","DeleteOnTermination":true}},
  {"DeviceName":"/dev/sdf","Ebs":{"VolumeSize":${ENV_EBS_GB},"VolumeType":"${EBS_VOLUME_TYPE}","DeleteOnTermination":false}}
]
JSON
)"
    info "Launching ${ENV_INSTANCE_TYPE} with 30GB root + ${ENV_EBS_GB}GB ${EBS_VOLUME_TYPE} data volume, monitoring=${ENV_MONITORING}"
    iid="$(aws ec2 run-instances \
      --image-id "${ami}" \
      --instance-type "${ENV_INSTANCE_TYPE}" \
      --key-name "${EC2_KEY_NAME}" \
      --subnet-id "${SUBNET_ID}" \
      --security-group-ids "${SG_ID}" \
      --monitoring "${mon_flag}" \
      --placement "Tenancy=${ENV_TENANCY}" \
      --block-device-mappings "${bdm}" \
      --tag-specifications \
        "ResourceType=instance,Tags=[{Key=Name,Value=$(tag_name "${e}")},{Key=Project,Value=${PROJECT_NAME}},{Key=Environment,Value=${e}}]" \
        "ResourceType=volume,Tags=[{Key=Name,Value=$(tag_name "${e}")-vol},{Key=Project,Value=${PROJECT_NAME}},{Key=Environment,Value=${e}}]" \
      --query 'Instances[0].InstanceId' --output text)"
    ok "Instance ${iid} launching"
    info "Waiting for instance to reach 'running' ..."
    aws ec2 wait instance-running --instance-ids "${iid}"
  fi

  # Elastic IP (stable public address for DNS + SSL)
  local alloc eip
  alloc="$(aws ec2 describe-addresses \
    --filters "Name=tag:Name,Values=$(tag_name "${e}")-eip" \
    --query 'Addresses[0].AllocationId' --output text | grep -v '^None$' || true)"
  if [[ -z "${alloc}" ]]; then
    alloc="$(aws ec2 allocate-address --domain vpc \
      --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=$(tag_name "${e}")-eip},{Key=Project,Value=${PROJECT_NAME}}]" \
      --query 'AllocationId' --output text)"
    ok "Allocated Elastic IP (${alloc})"
  fi
  aws ec2 associate-address --instance-id "${iid}" --allocation-id "${alloc}" >/dev/null
  eip="$(aws ec2 describe-addresses --allocation-ids "${alloc}" --query 'Addresses[0].PublicIp' --output text)"

  state_set "${e}" INSTANCE_ID "${iid}"
  state_set "${e}" EIP_ALLOC "${alloc}"
  state_set "${e}" PUBLIC_IP "${eip}"
  ok "${e} ready -> instance ${iid} @ ${eip}"
}

# =============================================================================
# MAIN
# =============================================================================
provision_network
provision_security_group
provision_keypair
for e in "${TARGET_ENVS[@]}"; do provision_instance "${e}"; done

checkpoint "CHECKPOINT 1 COMPLETE - AWS provisioned"
for e in "${TARGET_ENVS[@]}"; do
  state_load "${e}"
  echo "  ${C_BOLD}${e}${C_RESET}: ${PUBLIC_IP}  (instance ${INSTANCE_ID})"
done
cat <<NOTE

Next steps:
  1) Point DNS A-records at the Elastic IPs above:
        ${PRODUCTION_DOMAIN} -> production EIP
        ${STAGING_DOMAIN}    -> staging EIP
  2) Reserved Instances / Savings Plan (3yr, No Upfront) are a BILLING purchase,
     not created by run-instances. Purchase to match the running on-demand shapes:
        aws ec2 purchase-reserved-instances-offering  (or a Compute Savings Plan)
        production: 1x t3.large  |  staging: 1x t3.medium  | region ${AWS_REGION}
     See README section "Reserved Instances" for the exact command.
  3) Run ./02-deploy-odoo.sh
NOTE
