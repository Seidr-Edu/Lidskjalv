.PHONY: scan-batch scan-one create-projects service-help test docker-build

scan-batch:
	./scripts/batch-scan.sh

scan-one:
	./scripts/scan-one.sh

create-projects:
	./scripts/create-projects.sh

service-help:
	./lidskjalv-service.sh --help

test:
	bash tests/run.sh

docker-build:
	docker build -t lidskjalv:local .
