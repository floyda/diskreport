.PHONY: build test lint release bundle clean

build:
	swift build

test: lint
	swift test

lint:
	Scripts/lint-readonly.sh

release: lint
	swift build -c release

bundle: release
	chmod +x Scripts/bundle-app.sh
	Scripts/bundle-app.sh

clean:
	rm -rf .build build
