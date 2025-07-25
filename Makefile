.PHONY: install format-sol format-python test build

install:
	forge install

format-sol:
	forge fmt

format-python:
	black scripts/

test:
	forge test -vv --via-ir

build:
	forge build --via-ir
