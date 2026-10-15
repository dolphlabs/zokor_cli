# zokor_cli

The `zokor` command: it starts services built on
[zokor](https://github.com/dolphlabs/zokor), the slang web framework,
adds features and routes to them, checks their layout and runs their
migrations.

## Install

You need [slang](https://github.com/dolphlabs/slang/releases) 0.2.3 or
later, git and make.

```sh
curl -fsSL https://raw.githubusercontent.com/dolphlabs/zokor_cli/main/install.sh | sh
```

This builds the latest release with your `slangc` and installs it as
`~/.local/bin/zokor`. Set `PREFIX` to put it somewhere else, or
`ZOKOR_CLI_VERSION=v0.2.0` to pick a release. From a checkout,
`make install` (or `make install PREFIX=~/.local`) does the same.

## Start a service

```sh
zokor new billing
cd billing
slangc get
make run        # serves on :8080; GET /healthz
```

`zokor new` writes a small service: startup, config and a health check.
`zokor newcomp` writes the full layout, with a sample feature split into
domain, service, store and server, auth, and `--db pg` for Postgres.

## Commands

```
zokor version               this CLI, and the zokor release new projects pin
zokor new <name> [--zokor-git URL] [--zokor-tag TAG]
zokor newcomp <name> [--db memory|pg] [--zokor-git URL] [--zokor-tag TAG]
zokor add feature <name> [--entity <singular>]
zokor add route <feature> <METHOD> <path> <handler>
zokor check [--json]        the layout rules, from the service's root
zokor migrate [directory]   (default: migrations; DATABASE_URL required)
```

A new project pins the zokor release this CLI was built against
(`zokor version` prints it). `--zokor-tag` and `--zokor-git` pin another.

## Development

```sh
make build      # bin/zokor
make test       # tests/cli.sh and tests/scaffold.sh
make check      # those, plus templates-check
```

`cmd/zokor/templates/` holds the generated files. After you edit one,
run `make templates` to regenerate `cmd/zokor/templates.sl`.

`tests/scaffold.sh` generates every kind of project and builds, tests and
serves it. By default it uses the zokor tag pinned in `slang.project`.
Set `ZOKOR_SRC=/path/to/zokor` to use a local checkout instead.
`ZOKOR_TEST_DATABASE_URL` and `SCAFFOLD_TEST_DATABASE_URL` turn on the
live Postgres parts.

Releases: see `.github/workflows/release.yml`.

## License

See [LICENSE](LICENSE).
