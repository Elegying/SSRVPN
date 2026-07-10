.PHONY: status sync assets verify deps pub-get analyze test format feature

status:
	@scripts/project-status.sh

sync:
	@scripts/sync-main.sh

assets:
	@scripts/bootstrap-core-assets.sh

verify:
	@scripts/verify-all.sh

deps:
	@scripts/check-dependencies.sh

pub-get:
	@scripts/workspace.sh pub-get

analyze:
	@scripts/workspace.sh analyze

test:
	@scripts/workspace.sh test

format:
	@scripts/workspace.sh format

feature:
	@if [ -z "$(name)" ]; then \
		echo "Usage: make feature name=short-feature-name"; \
		exit 1; \
	fi
	@scripts/start-feature.sh "$(name)"
