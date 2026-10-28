# zokor_cli

The `zokor` command: it starts services built on
[zokor](https://github.com/dolphlabs/zokor), the slang web framework,
adds features and routes to them, checks their layout and runs their
migrations.

## Install

You need [slang](https://github.com/dolphlabs/slang/releases) 0.2.4 or
later, git and make. With slang 0.2.5 or later, `zokor watch` uses slang's
development builds, which rebuild several times faster.

```sh
curl -fsSL https://raw.githubusercontent.com/dolphlabs/zokor_cli/main/install.sh | sh
```

This builds the latest release with your `slangc` and installs it as
`~/.local/bin/zokor`. Set `PREFIX` to put it somewhere else, or
`ZOKOR_CLI_VERSION=v0.2.2` to pick a release. From a checkout,
`make install` (or `make install PREFIX=~/.local`) does the same.

## Start a service

```sh
zokor new billing
cd billing
slangc get
make dev        # or `zokor watch`: watches src/, rebuilds & reloads on edit
# or `make run` / `zokor start` for a single foreground run
```

`zokor new` writes a small service: startup, config and a health check.
`zokor newcomp` writes the full layout, with a sample feature split into
domain, service, store and server, auth, and `--db pg` for Postgres.

## Commands

```
zokor version               this CLI, and the zokor release new projects pin
zokor start [--watch]       build and start the service (or watch mode)
zokor watch                 alias for zokor start --watch
zokor new <name> [--zokor-git URL] [--zokor-tag TAG]
zokor newcomp <name> [--db memory|pg] [--zokor-git URL] [--zokor-tag TAG]
zokor add feature <name> [--entity <singular>]
zokor add route <feature> <METHOD> <path> <handler>
zokor check [--json]        the layout rules, from the service's root
zokor migrate [directory]   (default: migrations; DATABASE_URL required)
```

A new project pins the zokor release this CLI was built against
(`zokor version` prints it). `--zokor-tag` and `--zokor-git` pin another.

## Watch Mode

`zokor watch` (or `zokor start --watch`, or `make dev` in a generated project) runs your service under an active file watcher:

- **Kernel events**: Uses native OS kernel notifications (`FSEvents` on macOS, `inotify` on Linux) with zero CPU polling overhead.
- **Atomic staging**: Recompiles the service beside the running application (`.zokor/watch/app.next`) before swapping. If a compile error occurs (syntax error, type mismatch), the error is logged and the previous server continues running without interruption.
- **Graceful restart**: Sends `SIGTERM` to the server's process group, allows graceful connection teardown, and force-kills if unresponsive before starting the new build.
- **Crash policy**: If the application exits or crashes, the supervisor enters an idle state waiting for the next source edit rather than spinning in a restart loop.
- **Fast builds**: Watch builds are slang development builds (`SLANG_DEV=1`): unoptimized C that compiles about ten times faster, so a large service rebuilds in seconds rather than minutes. The program runs slower; `zokor watch --release` builds optimized. Needs slang 0.2.5 or later; an older `slangc` ignores the setting and builds optimized.
- **Saves during a build**: A save while a build is running cancels that build and starts a new one, so the server never runs code older than your last save.

## Development

```sh
make build      # bin/zokor
make test       # the unit tests, tests/cli.sh, tests/watch.sh and tests/scaffold.sh
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
