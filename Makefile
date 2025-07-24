.PHONY: format-sol format-python test build

format-sol:
	forge fmt

format-python:
	black scripts/

test:
	forge test -vv --via-ir

build:
	forge build --via-ir
