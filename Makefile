.PHONY: build test lint release clean

build:
	swift build

test: lint
	swift test

lint:
	Scripts/lint-readonly.sh

release: lint
	swift build -c release

clean:
	rm -rf .build build
