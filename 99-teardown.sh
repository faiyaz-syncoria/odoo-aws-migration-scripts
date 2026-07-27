#!/usr/bin/env bash
# =============================================================================
# 99-teardown.sh  -  DESTROY all AWS resources created for this project.
# -----------------------------------------------------------------------------
# Deletes, in dependency order, everything tagged Project=${PROJECT_NAME}:
#   EC2 instances -> Elastic IPs -> data EBS volumes -> security group ->
#   route table -> internet gateway -> subnet -> VPC -> EC2 key pair.
# Then clears local .state/. Idempotent: skips anything already gone.
#
# ⚠  IRREVERSIBLE. This erases the migrated databases and filestores on AWS.
#    It does NOT touch odoo.sh. Use to reset before a clean re-run.
#
# Usage:
#   ./99-teardown.sh                 # both environments + shared network
#   ./99-teardown.sh production      # just one env's instance + its EIP
#   ASSUME_YES=1 ./99-teardown.sh    # skip the typed confirmation (CI)
# =============================================================================
source "$(dirname "$0")/lib/common.sh"
load_config
check_aws_auth

TARGET_ENVS=("$@"); SINGLE=1
if [[ ${#TARGET_ENVS[@]} -eq 0 ]]; then TARGET_ENVS=("${ENVIRONMENTS[@]}"); SINGLE=0; fi

PROJ_FILTER=(--filters "Name=tag:Project,Values=${PROJECT_NAME}")

checkpoint "TEARDOWN - project '${PROJECT_NAME}' in ${AWS_REGION}"
warn "This will PERMANENTLY DELETE the AWS instances, volumes and (if full run) the"
warn "network for project '${PROJECT_NAME}'. odoo.sh is untouched."
echo "Scope: ${TARGET_ENVS[*]}$([[ ${SINGLE} -eq 0 ]] && echo ' + shared network (SG/subnet/IGW/VPC/keypair)')"
if [[ "${ASSUME_YES:-0}" != "1" ]]; then
  read -r -p "Type the project name '${PROJECT_NAME}' to confirm: " ans || true
  [[ "${ans}" == "${PROJECT_NAME}" ]] || die "Confirmation did not match - aborted."
fi

# ---- instances + their Elastic IPs -----------------------------------------
declare -a TERMINATED=()
for e in "${TARGET_ENVS[@]}"; do
  iid="$(aws_instance_id "${e}")"
  if [[ -n "${iid}" ]]; then
    info "Terminating ${e} instance ${iid}"
    aws ec2 terminate-instances --instance-ids "${iid}" >/dev/null
    TERMINATED+=("${iid}")
  else
    ok "${e}: no instance to terminate"
  fi
  # release the env's Elastic IP
  alloc="$(aws ec2 describe-addresses --filters "Name=tag:Name,Values=$(tag_name "${e}")-eip" \
    --query 'Addresses[0].AllocationId' --output text 2>/dev/null | grep -v '^None$' || true)"
  if [[ -n "${alloc}" ]]; then
    assoc="$(aws ec2 describe-addresses --allocation-ids "${alloc}" --query 'Addresses[0].AssociationId' --output text 2>/dev/null | grep -v '^None$' || true)"
    [[ -n "${assoc}" ]] && aws ec2 disassociate-address --association-id "${assoc}" >/dev/null 2>&1 || true
  fi
done

if [[ ${#TERMINATED[@]} -gt 0 ]]; then
  info "Waiting for instance termination ..."
  aws ec2 wait instance-terminated --instance-ids "${TERMINATED[@]}" || true
  ok "Instances terminated"
fi

# release EIPs now that instances are gone
for e in "${TARGET_ENVS[@]}"; do
  alloc="$(aws ec2 describe-addresses --filters "Name=tag:Name,Values=$(tag_name "${e}")-eip" \
    --query 'Addresses[0].AllocationId' --output text 2>/dev/null | grep -v '^None$' || true)"
  if [[ -n "${alloc}" ]]; then
    aws ec2 release-address --allocation-id "${alloc}" >/dev/null 2>&1 && ok "Released Elastic IP (${e})" || warn "Could not release EIP ${alloc}"
  fi
done

# delete data volumes left behind (DeleteOnTermination=false), tagged to project
info "Deleting orphaned data volumes"
for vol in $(aws ec2 describe-volumes "${PROJ_FILTER[@]}" "Name=status,Values=available" \
              --query 'Volumes[].VolumeId' --output text 2>/dev/null); do
  aws ec2 delete-volume --volume-id "${vol}" >/dev/null 2>&1 && ok "Deleted volume ${vol}" || warn "Could not delete ${vol}"
done

# ---- shared network (only on a full teardown) ------------------------------
if [[ ${SINGLE} -eq 0 ]]; then
  VPC_ID="$(aws_vpc_id)"
  if [[ -n "${VPC_ID}" ]]; then
    checkpoint "Removing shared network (${VPC_ID})"

    # security group (can't delete until instances are gone)
    SG_ID="$(aws ec2 describe-security-groups --filters "Name=tag:Name,Values=$(tag_name sg)" "Name=vpc-id,Values=${VPC_ID}" \
      --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null | grep -v '^None$' || true)"
    if [[ -n "${SG_ID}" ]]; then
      for _ in 1 2 3 4 5 6; do aws ec2 delete-security-group --group-id "${SG_ID}" >/dev/null 2>&1 && { ok "Deleted SG ${SG_ID}"; SG_ID=""; break; } || sleep 10; done
      [[ -n "${SG_ID}" ]] && warn "Could not delete SG ${SG_ID} (dependencies still detaching?)"
    fi

    # subnet
    SUBNET_ID="$(aws ec2 describe-subnets --filters "Name=tag:Name,Values=$(tag_name subnet)" "Name=vpc-id,Values=${VPC_ID}" \
      --query 'Subnets[0].SubnetId' --output text 2>/dev/null | grep -v '^None$' || true)"
    [[ -n "${SUBNET_ID}" ]] && { aws ec2 delete-subnet --subnet-id "${SUBNET_ID}" >/dev/null 2>&1 && ok "Deleted subnet ${SUBNET_ID}" || warn "Could not delete subnet ${SUBNET_ID}"; }

    # route table (disassociate non-main associations, then delete)
    RT_ID="$(aws ec2 describe-route-tables --filters "Name=tag:Name,Values=$(tag_name rt)" "Name=vpc-id,Values=${VPC_ID}" \
      --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null | grep -v '^None$' || true)"
    if [[ -n "${RT_ID}" ]]; then
      for a in $(aws ec2 describe-route-tables --route-table-ids "${RT_ID}" --query 'RouteTables[0].Associations[?Main==`false`].RouteTableAssociationId' --output text 2>/dev/null); do
        aws ec2 disassociate-route-table --association-id "${a}" >/dev/null 2>&1 || true
      done
      aws ec2 delete-route-table --route-table-id "${RT_ID}" >/dev/null 2>&1 && ok "Deleted route table ${RT_ID}" || warn "Could not delete route table ${RT_ID}"
    fi

    # internet gateway (detach then delete)
    IGW_ID="$(aws ec2 describe-internet-gateways --filters "Name=tag:Name,Values=$(tag_name igw)" \
      --query 'InternetGateways[0].InternetGatewayId' --output text 2>/dev/null | grep -v '^None$' || true)"
    if [[ -n "${IGW_ID}" ]]; then
      aws ec2 detach-internet-gateway --internet-gateway-id "${IGW_ID}" --vpc-id "${VPC_ID}" >/dev/null 2>&1 || true
      aws ec2 delete-internet-gateway --internet-gateway-id "${IGW_ID}" >/dev/null 2>&1 && ok "Deleted IGW ${IGW_ID}" || warn "Could not delete IGW ${IGW_ID}"
    fi

    # vpc
    aws ec2 delete-vpc --vpc-id "${VPC_ID}" >/dev/null 2>&1 && ok "Deleted VPC ${VPC_ID}" || warn "Could not delete VPC ${VPC_ID} (leftover ENIs/dependencies?)"
  else
    ok "No project VPC found - network already clean"
  fi

  # key pair (AWS side); local .pem left in secrets/ for you to remove if desired
  if aws ec2 describe-key-pairs --key-names "${EC2_KEY_NAME}" >/dev/null 2>&1; then
    aws ec2 delete-key-pair --key-name "${EC2_KEY_NAME}" >/dev/null 2>&1 && ok "Deleted key pair ${EC2_KEY_NAME}" || warn "Could not delete key pair"
  fi
fi

# ---- clear local state ------------------------------------------------------
if [[ ${SINGLE} -eq 0 ]]; then
  rm -f "${STATE_DIR}"/*.env 2>/dev/null || true
  ok "Cleared local .state/"
else
  for e in "${TARGET_ENVS[@]}"; do rm -f "$(state_file "${e}")" 2>/dev/null || true; done
fi

checkpoint "TEARDOWN COMPLETE"
cat <<NOTE
Verify nothing lingers:
  aws ec2 describe-instances --filters Name=tag:Project,Values=${PROJECT_NAME} \\
    "Name=instance-state-name,Values=pending,running,stopping,stopped" \\
    --query 'Reservations[].Instances[].InstanceId' --output text
  aws ec2 describe-vpcs --filters Name=tag:Project,Values=${PROJECT_NAME} --query 'Vpcs[].VpcId' --output text

Local .pem and the security-group Cloudflare rules (if any) are independent of AWS
teardown. To start fully fresh, also: rm -f secrets/${EC2_KEY_NAME}.pem
NOTE
