.PHONY: help lint lint-strict test env inventory install bundle paste-kit
help:        ## show targets
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | sed 's/:.*##/ —/'
lint:        ## bash -n + CRLF check (+ shellcheck if installed)
	@tests/lint.sh
lint-strict: ## same, but shellcheck warnings fail
	@STRICT=1 tests/lint.sh
test:        ## unit tests (no database or root needed)
	@bash tests/epas-detect-unit.sh
	@bash tests/epas-ssl-unit.sh
	@bash tests/epas-layout-unit.sh
	@bash tests/epas-tde-unit.sh
	@bash tests/logger-unit.sh
	@bash tests/common-unit.sh
	@bash tests/backup-unit.sh
	@bash tests/restore-test-unit.sh
	@bash tests/efm-reconfigure-unit.sh
	@bash tests/efm-setup-unit.sh
	@bash tests/paste-kit-unit.sh
env:         ## create conf/site.env and conf/tde.env from the templates (won't overwrite)
	@cp -n conf/site.env.example conf/site.env && echo "created conf/site.env" || true
	@cp -n conf/tde.env.example conf/tde.env && echo "created conf/tde.env" || true
inventory:   ## read-only report of EDB/PostgreSQL software, instances, EFM on this host
	@bash tools/get-edb-inventory.sh
install:     ## install this copy into /opt/dba/edb_toolkit (root; PREFIX=... to change)
	@bash tools/install.sh
bundle:      ## dist/edb_toolkit-<version>.tar.gz for servers without Git access
	@bash tools/make-bundle.sh
paste-kit:   ## dist/paste-kit-<version>/ : the toolkit as plain text parts to paste (no file transfer possible)
	@bash tools/make-paste-kit.sh
