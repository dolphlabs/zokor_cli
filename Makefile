SLANGC ?= slangc
PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin

.PHONY: build install uninstall templates templates-check test check clean

# The CLI, against the zokor release slang.project pins.
build:
	$(SLANGC) get
	mkdir -p bin
	$(SLANGC) cmd/zokor/main.sl -o bin/zokor

# `make install` (or PREFIX=~/.local make install) puts `zokor` on PATH,
# which is where a generated project's `make check` looks for it.
install: build
	install -d "$(DESTDIR)$(BINDIR)"
	install -m 755 bin/zokor "$(DESTDIR)$(BINDIR)/zokor"

uninstall:
	rm -f "$(DESTDIR)$(BINDIR)/zokor"

# cmd/zokor/templates.sl embeds cmd/zokor/templates/ for `zokor new` and
# `zokor add`; templates-check fails when someone edited a template and
# did not regenerate it.
templates:
	sh cmd/zokor/gen_templates.sh

templates-check:
	sh cmd/zokor/gen_templates.sh --check

# tests/scaffold.sh generates every kind of project against a zokor
# checkout (ZOKOR_SRC, or the pinned tag, cloned) and builds, runs and
# tests them. SCAFFOLD_TEST_DATABASE_URL and ZOKOR_TEST_DATABASE_URL turn
# on the live Postgres parts.
test: build
	sh tests/cli.sh
	sh tests/watch.sh
	SLANGC="$(SLANGC)" sh tests/scaffold.sh

check: templates-check test

clean:
	rm -rf bin
