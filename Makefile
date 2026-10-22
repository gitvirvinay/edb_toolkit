.PHONY: help lint lint-strict env inventory
help:        ## show targets
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | sed 's/:.*##/ —/'
lint:        ## bash -n + CRLF check (+ shellcheck if installed)
	@tests/lint.sh
lint-strict: ## same, but shellcheck warnings fail
	@STRICT=1 tests/lint.sh
env:         ## create conf/site.env and conf/tde.env from the templates (won't overwrite)
	@cp -n conf/site.env.example conf/site.env && echo "created conf/site.env" || true
	@cp -n conf/tde.env.example conf/tde.env && echo "created conf/tde.env" || true
inventory:   ## read-only report of EDB/PostgreSQL software, instances, EFM on this host
	@bash tools/get-edb-inventory.sh
