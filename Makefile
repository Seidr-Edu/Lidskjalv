.PHONY: scan-batch scan-one create-projects andvari

scan-batch:
	./scripts/batch-scan.sh

scan-one:
	./scripts/scan-one.sh

create-projects:
	./scripts/create-projects.sh

andvari:
	./andvari-run.sh --help
