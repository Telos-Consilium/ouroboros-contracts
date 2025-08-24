.PHONY: install format-sol format-python format test coverage coverage-html build

install:
	forge install

format-sol:
	forge fmt

format-python:
	black scripts/

format: format-sol format-python

test:
	forge test

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
