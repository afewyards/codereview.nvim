.PHONY: setup lint format test

setup:
	git config core.hooksPath .githooks

lint:
	luacheck lua/ plugin/ tests/

format:
	stylua lua/ plugin/ tests/

test:
	busted --run unit tests/
