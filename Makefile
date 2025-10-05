.PHONY: install format-sol format-python format test invariants-fail-on-revert coverage coverage-html slither build local-deploy

install:
	forge install

format-sol:
	forge fmt

format-python:
	black scripts/

format: format-sol format-python

test:
	forge test

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
	slitherin ./src --config-file slither.config.json

build:
	forge build

# [!] Do not use plaintext private keys in production
local-deploy:
	forge script scripts/Deploy.s.sol:Deploy --fork-url http://localhost:8545 --broadcast --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
