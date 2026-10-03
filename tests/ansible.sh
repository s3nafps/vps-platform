#!/usr/bin/env bash
# Converge the host roles in a systemd container, prove the second run changes
# nothing, then verify the result. Requires Docker and the collections in
# ansible/requirements.yml.
set -euo pipefail

cd "$(dirname "$0")/ansible"
IMAGE=${TEST_IMAGE:-geerlingguy/docker-ubuntu2404-ansible:latest}
NAME=vps-test
export ANSIBLE_ROLES_PATH="$PWD/../../ansible/roles"
export ANSIBLE_CONFIG="$PWD/../../ansible/ansible.cfg"
export ANSIBLE_INVENTORY="$PWD/inventory.yml"
export ANSIBLE_FORCE_COLOR=1

cleanup() { [[ "${KEEP:-0}" == "1" ]] || docker rm -f "$NAME" > /dev/null 2>&1 || true; }
trap cleanup EXIT

docker rm -f "$NAME" > /dev/null 2>&1 || true
docker run -d --name "$NAME" --hostname "$NAME" --privileged --cgroupns=host \
  ${DOCKER_NETWORK:+--network "$DOCKER_NETWORK"} \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw "$IMAGE" > /dev/null
for _ in $(seq 1 30); do
  state=$(docker exec "$NAME" systemctl is-system-running 2> /dev/null || true)
  [[ "$state" == "running" || "$state" == "degraded" ]] && break
  sleep 1
done

# Optional: trust an extra CA inside the container (for TLS-intercepting proxies).
if [[ -n "${EXTRA_CA_CERT:-}" ]]; then
  docker cp "$EXTRA_CA_CERT" "$NAME:/usr/local/share/ca-certificates/extra-ca.crt"
  docker exec "$NAME" update-ca-certificates > /dev/null
fi

echo "==> prepare"
ansible-playbook prepare.yml
echo "==> converge"
ansible-playbook converge.yml
echo "==> idempotence"
log=$(mktemp)
ansible-playbook converge.yml | tee "$log"
if grep -qE 'changed=[1-9]' "$log"; then
  echo "Second run reported changes; the roles are not idempotent." >&2
  exit 1
fi
echo "==> verify"
ansible-playbook verify.yml
