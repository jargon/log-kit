.PHONY: build check fmt-check vet test blackbox fuzz-smoke

BIN := $(CURDIR)/bin/log

build:
	go build -o $(BIN) ./cmd/log

fmt-check:
	@out=$$(gofmt -l . ); if [ -n "$$out" ]; then echo "gofmt needed:"; echo "$$out"; exit 1; fi

vet:
	go vet ./...

test:
	go test -race ./...

blackbox: build
	cd test/blackbox && LOG_BIN=$(BIN) go test -count=1 ./...

# Runs each fuzz target for 30 s. Targets are discovered by name.
fuzz-smoke:
	@for pkg in $$(go list ./...); do \
	  for t in $$(go test -list "^Fuzz" $$pkg | grep "^Fuzz"); do \
	    echo "== $$pkg $$t"; go test -run=^$$ -fuzz="^$$t$$" -fuzztime=30s $$pkg || exit 1; \
	  done; \
	done

check: fmt-check vet test blackbox
