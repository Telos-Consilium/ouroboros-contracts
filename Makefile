.PHONY: install format-sol format-python format test coverage build

install:
	forge install

format-sol:
	forge fmt

format-python:
	black scripts/

format: format-sol format-python

test:
	forge test -vv

coverage:
	forge coverage --ir-minimum

build:
	forge build
