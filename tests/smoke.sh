#!/usr/bin/env bash
# End-to-end smoke test: start the whole stack with *.localhost domains (Caddy issues
# certificates from its internal CA for those) and check that every part works.
# Usage: tests/smoke.sh            # start, test, tear down
#        KEEP=1 tests/smoke.sh     # leave the stack running afterwards
set -euo pipefail

cd "$(dirname "$0")/../stack"
export COMPOSE_PROJECT_NAME=platform-smoke
GRAFANA_PASSWORD="smoke-$(date +%s)"

cat > .env <<ENV
ACME_EMAIL=ci@example.com
STATUS_DOMAIN=status.localhost
GRAFANA_DOMAIN=grafana.localhost
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=${GRAFANA_PASSWORD}
ENV
cp alertmanager/alertmanager.example.yml alertmanager/alertmanager.yml
cat > prometheus/targets/probes.yml <<'YAML'
- targets: ["http://grafana:3000/api/health"]
  labels: { group: smoke }
YAML

failures=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; failures=$((failures + 1)); }

cleanup() {
  status=$?
  if [[ $status -ne 0 || $failures -gt 0 ]]; then
    echo "--- docker compose ps"
    docker compose ps -a || true
    echo "--- last log lines"
    docker compose logs --tail 30 || true
  fi
  if [[ "${KEEP:-0}" != "1" ]]; then
    docker compose down -v --remove-orphans >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

curl_site() { # host path [extra curl args]
  local host=$1 path=$2; shift 2
  curl -sk --max-time 10 --resolve "${host}:443:127.0.0.1" "$@" "https://${host}${path}"
}

retry() { # seconds description command...
  local deadline=$((SECONDS + $1)) description=$2; shift 2
  until "$@" >/dev/null 2>&1; do
    if ((SECONDS >= deadline)); then fail "$description"; return 1; fi
    sleep 3
  done
  pass "$description"
}

echo "==> Starting stack"
docker compose up -d --wait --wait-timeout 240

echo "==> Edge"
retry 60 "status page served over HTTPS" \
  bash -c "[[ \$(curl -sk -o /dev/null -w '%{http_code}' --resolve status.localhost:443:127.0.0.1 https://status.localhost/) =~ ^(200|302)$ ]]"
retry 60 "Grafana healthy behind Caddy" \
  bash -c "curl -sk --resolve grafana.localhost:443:127.0.0.1 https://grafana.localhost/api/health | grep -q '\"database\": *\"ok\"'"
if curl_site status.localhost / -I | grep -qi '^strict-transport-security'; then pass "security headers set"; else fail "security headers set"; fi
if curl_site status.localhost / -I | grep -qi '^server:'; then fail "Server header removed"; else pass "Server header removed"; fi

echo "==> Exposure"
public=$(docker compose ps --format json | python3 -c '
import json, sys
ports = set()
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    items = json.loads(line)
    for item in (items if isinstance(items, list) else [items]):
        for p in item.get("Publishers") or []:
            if p.get("PublishedPort") and p.get("URL") not in ("127.0.0.1", "::1"):
                ports.add(p["PublishedPort"])
print(" ".join(str(p) for p in sorted(ports)))')
if [[ "$public" == "443 80" || "$public" == "80 443" ]]; then pass "only 80/443 published publicly ($public)"; else fail "only 80/443 published publicly (got: $public)"; fi

echo "==> Metrics"
targets_up() {
  curl -s --max-time 5 http://127.0.0.1:9090/api/v1/targets | python3 -c '
import json, sys
data = json.load(sys.stdin)["data"]["activeTargets"]
required = {"prometheus", "node", "cadvisor", "caddy", "alertmanager", "loki", "alloy", "blackbox"}
up = {t["labels"]["job"] for t in data if t["health"] == "up"}
missing = required - up
sys.exit(1 if missing else 0)'
}
retry 150 "all Prometheus targets up" targets_up || curl -s http://127.0.0.1:9090/api/v1/targets | python3 -c '
import json, sys
for t in json.load(sys.stdin)["data"]["activeTargets"]:
    print("   ", t["labels"]["job"], t["health"], t.get("lastError", ""))'

rules=$(curl -s http://127.0.0.1:9090/api/v1/rules | python3 -c 'import json,sys; print(sum(len(g["rules"]) for g in json.load(sys.stdin)["data"]["groups"]))')
if [[ "$rules" -ge 15 ]]; then pass "alert rules loaded ($rules)"; else fail "alert rules loaded ($rules)"; fi

if curl -s http://127.0.0.1:9093/api/v2/status | grep -q '"cluster"'; then pass "Alertmanager API reachable on localhost"; else fail "Alertmanager API reachable on localhost"; fi

echo "==> Grafana"
for ds in prometheus loki; do
  retry 60 "Grafana datasource '$ds' healthy" \
    bash -c "curl -sk -u admin:${GRAFANA_PASSWORD} --resolve grafana.localhost:443:127.0.0.1 https://grafana.localhost/api/datasources/uid/${ds}/health | grep -q '\"status\": *\"OK\"'"
done
if curl_site grafana.localhost /api/dashboards/uid/platform-overview -u "admin:${GRAFANA_PASSWORD}" | grep -q '"title":"Platform overview"'; then
  pass "dashboard provisioned"
else
  fail "dashboard provisioned"
fi

echo "==> Logs"
retry 90 "container logs arriving in Loki" \
  bash -c "curl -sk -u admin:${GRAFANA_PASSWORD} --resolve grafana.localhost:443:127.0.0.1 'https://grafana.localhost/api/datasources/proxy/uid/loki/loki/api/v1/label/service/values' | grep -q 'grafana'"

echo
if [[ $failures -gt 0 ]]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "All checks passed"
