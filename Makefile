.PHONY: install format-sol fmt-check format-python format test test-invariants test-v1 test-v2 invariants-fail-on-revert coverage coverage-html slither check-submodules build build-production

SUBMODULE_PATHS := $(shell git config --file .gitmodules --get-regexp path | awk '{print $$2}')

install:
	forge install

format-sol:
	forge fmt

fmt-check:
	forge fmt --check

format-python:
	black scripts/

format: format-sol format-python

test:
	forge test

test-invariants:
	forge test --match-test invariantTest_

test-v1:
	forge test --no-match-contract V2 --no-match-test invariantTest_

test-v2:
	forge test --match-contract V2 --no-match-test invariantTest_

invariants-fail-on-revert:
	FOUNDRY_INVARIANT_FAIL_ON_REVERT=true USE_GUARDRAILS=true forge test --match-test invariantTest_

coverage:
	forge coverage \
		--ir-minimum \
		--report lcov \
		--report summary \
		--report-file coverage/lcov.info \
		--no-match-coverage "test/"

coverage-html:
	mkdir -p coverage/html
	genhtml coverage/lcov.info --output-directory coverage/html
	open coverage/html/index.html

slither:
	slitherin . --config-file slither.config.json

check-submodules:
	git submodule status --recursive
	git diff --exit-code --submodule=log -- .gitmodules $(SUBMODULE_PATHS)
	git diff --cached --exit-code --submodule=log -- .gitmodules $(SUBMODULE_PATHS)

build:
	forge build

build-production:
	FOUNDRY_PROFILE=production forge build --sizes
