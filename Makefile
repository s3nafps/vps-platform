SHELL := /bin/bash
STACK := stack
ANSIBLE := ansible
PROM_IMAGE := prom/prometheus:v3.1.0
AM_IMAGE := prom/alertmanager:v0.28.0
CADDY_IMAGE := caddy:2.8-alpine
ALLOY_IMAGE := grafana/alloy:v1.5.1
LOKI_IMAGE := grafana/loki:3.3.2
HOST ?= vps01

.PHONY: help init lint validate test test-stack test-ansible deploy deploy-stack backup restore-test tunnel

help: ## Show targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-14s %s\n", $$1, $$2}'

init: ## Create local config files from the examples (does not overwrite)
	@cp -n $(STACK)/.env.example $(STACK)/.env || true
	@cp -n $(STACK)/alertmanager/alertmanager.example.yml $(STACK)/alertmanager/alertmanager.yml || true
	@cp -n $(STACK)/prometheus/targets/probes.example.yml $(STACK)/prometheus/targets/probes.yml || true
	@cp -n $(ANSIBLE)/inventory/hosts.example.yml $(ANSIBLE)/inventory/hosts.yml || true
	@cp -n $(ANSIBLE)/group_vars/all/vault.example.yml $(ANSIBLE)/group_vars/all/vault.yml || true
	@echo "Edit the copied files, then: ansible-vault encrypt $(ANSIBLE)/group_vars/all/vault.yml"

lint: ## yamllint, ansible-lint, shellcheck
	yamllint -c .yamllint.yml .
	ansible-lint
	shellcheck tests/*.sh $(ANSIBLE)/roles/backup/files/*

validate: init ## Validate every service config with its own tool
	docker run --rm -v "$$PWD/$(STACK)/prometheus:/p" -w /p --entrypoint promtool $(PROM_IMAGE) check config prometheus.yml
	docker run --rm -v "$$PWD/$(STACK)/prometheus:/p" -w /p/tests --entrypoint promtool $(PROM_IMAGE) test rules rules_test.yml
	docker run --rm -v "$$PWD/$(STACK)/alertmanager:/a" --entrypoint amtool $(AM_IMAGE) check-config /a/alertmanager.example.yml
	docker run --rm -e ACME_EMAIL=a@example.com -e STATUS_DOMAIN=status.example.com -e GRAFANA_DOMAIN=grafana.example.com \
		-v "$$PWD/$(STACK)/caddy:/etc/caddy:ro" $(CADDY_IMAGE) caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
	docker run --rm -v "$$PWD/$(STACK)/alloy:/c:ro" $(ALLOY_IMAGE) fmt /c/config.alloy | diff - $(STACK)/alloy/config.alloy
	docker run --rm -v "$$PWD/$(STACK)/loki:/l:ro" $(LOKI_IMAGE) -config.file=/l/loki.yml -verify-config
	cd $(STACK) && docker compose config --quiet

test-stack: ## Start the full stack locally and run the smoke checks
	tests/smoke.sh

test-ansible: ## Converge the roles in a systemd container, check idempotence, verify
	tests/ansible.sh

test: lint validate test-stack test-ansible ## Everything CI runs

deploy: ## Provision the VPS (all roles)
	cd $(ANSIBLE) && ansible-playbook site.yml --ask-vault-pass

deploy-stack: ## Only update the Docker stack
	cd $(ANSIBLE) && ansible-playbook site.yml --tags stack --ask-vault-pass

backup: ## Run a backup now
	cd $(ANSIBLE) && ansible-playbook playbooks/backup-now.yml

restore-test: ## Restore the latest snapshot to scratch space and verify it
	cd $(ANSIBLE) && ansible-playbook playbooks/restore-test.yml

tunnel: ## Open Prometheus (9090) and Alertmanager (9093) on localhost through SSH
	ssh -N -L 9090:127.0.0.1:9090 -L 9093:127.0.0.1:9093 $(HOST)
