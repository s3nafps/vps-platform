# Runbooks

## Restore after losing the server

1. Create a new VPS with the same OS, point DNS at it, and update `ansible_host`.
2. Run the playbook once to rebuild the host and stack:
   `ansible-playbook site.yml -e ansible_user=root --ask-vault-pass`
3. Stop the stateful services and restore the latest snapshot:

   ```bash
   cd /opt/platform && docker compose stop uptime-kuma grafana caddy alertmanager
   set -a; . /etc/restic/restic.env; set +a
   restic snapshots --tag platform              # pick a snapshot, or use "latest"
   restic restore latest --tag platform --target /var/tmp/restore
   ```

4. Copy each volume back. Volume paths in the snapshot match `docker volume inspect`:

   ```bash
   for v in kuma-data grafana-data caddy-data alertmanager-data; do
     dst=$(docker volume inspect -f '{{ .Mountpoint }}' platform_$v)
     src=$(find /var/tmp/restore -path "*platform_${v}/_data" -type d | head -1)
     rsync -a --delete "$src/" "$dst/"
   done
   docker compose up -d
   ```

5. Confirm in Grafana that the *Last backup* panel updates after the next scheduled run.

## Restore a single file or volume

Use `restic restore latest --tag platform --include <path> --target /var/tmp/restore`,
then copy the file into place. `restic ls latest` lists what a snapshot contains.

## Rotate a secret

| Secret | Steps |
|---|---|
| Grafana admin password | Change `vault_grafana_admin_password`, then `make deploy-stack`. Grafana only reads the variable on first start, so also run `docker compose exec grafana grafana cli admin reset-admin-password '<new>'` |
| restic password | `restic key add`, update the vault, `make deploy`, then `restic key remove <old-id>` |
| Bucket keys | Create new keys at the provider, update `vault_backup_environment`, `make deploy`, run `make backup`, then delete the old keys |
| Telegram bot token | Revoke it in BotFather, update the vault, `make deploy-stack` |

## Add a service behind Caddy

1. Add the service to `stack/compose.yml` on the `edge` network, with no `ports:`.
2. Add a site block to `stack/caddy/Caddyfile` with `import security_headers`.
3. Add its URL to `platform_probe_targets` so it is probed and its certificate is watched.
4. `make validate && make test-stack`, then `make deploy-stack`.

## Alert responses

| Alert | First checks |
|---|---|
| `HostDown` | Provider console: is the VM running? `ssh` in and run `systemctl status docker` and `docker compose ps` |
| `HostDiskSpaceLow` / `Critical` | `df -h`, `docker system df`, `journalctl --disk-usage`. Prometheus is capped by `PROMETHEUS_RETENTION_SIZE` |
| `EndpointDown` | `docker compose logs caddy <service>`, check DNS, check the provider status page |
| `TlsCertificateExpiringSoon` | `docker compose logs caddy \| grep -i acme`. Usually DNS no longer points here, or port 80 is blocked |
| `BackupStale` / `BackupFailed` | `journalctl -u platform-backup.service -n 50`, then `make backup` once fixed |
| `RestoreTestStale` | `journalctl -u platform-restore-test.service -n 50` |
| `ContainerNearMemoryLimit` | `docker stats`. Raise `mem_limit` or investigate a leak |
