.PHONY: status sync verify deps feature

status:
	@scripts/project-status.sh

sync:
	@scripts/sync-main.sh

verify:
	@scripts/verify-all.sh

deps:
	@scripts/check-dependencies.sh

feature:
	@if [ -z "$(name)" ]; then \
		echo "Usage: make feature name=short-feature-name"; \
		exit 1; \
	fi
	@scripts/start-feature.sh "$(name)"
