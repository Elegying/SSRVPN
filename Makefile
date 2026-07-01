.PHONY: status sync verify feature

status:
	@scripts/project-status.sh

sync:
	@scripts/sync-main.sh

verify:
	@scripts/verify-all.sh

feature:
	@if [ -z "$(name)" ]; then \
		echo "Usage: make feature name=short-feature-name"; \
		exit 1; \
	fi
	@scripts/start-feature.sh "$(name)"
