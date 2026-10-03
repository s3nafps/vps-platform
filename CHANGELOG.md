# Changelog

## [1.0.0] - 2026-10-03

### Added
- Ansible roles: base, admin_user, ssh_hardening, firewall, fail2ban, docker, stack, backup.
- Compose stack: Caddy, Uptime Kuma, Prometheus, Alertmanager, node-exporter, cAdvisor,
  blackbox exporter, Loki, Alloy, Grafana with a provisioned dashboard.
- 18 alert rules with promtool unit tests.
- restic backups with retention, monthly automated restore tests and backup metrics.
- CI: lint, config validation, full-stack smoke test, Ansible converge/idempotence/verify.
