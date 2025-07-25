.PHONY: install format-sol format-python format test build

install:
	forge install

format-sol:
	forge fmt

format-python:
	black scripts/

format: format-sol format-python

test:
	forge test -vv

build:
	forge build
