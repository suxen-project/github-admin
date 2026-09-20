.PHONY: validate audit apply

validate:
	./scripts/validate.sh

audit: validate
	./scripts/reconcile.sh audit

apply: validate
	./scripts/reconcile.sh apply
