#!/bin/sh
# Installs the zokor CLI, building it from a release with your slangc:
#
#   curl -fsSL https://raw.githubusercontent.com/dolphlabs/zokor_cli/main/install.sh | sh
#
# ZOKOR_CLI_VERSION picks a release (e.g. v0.2.1; default: the latest).
# PREFIX is where it goes (default: $HOME/.local, so $HOME/.local/bin/zokor).
# ZOKOR_CLI_SOURCE builds a local checkout instead (what CI tests).
#
# Needs slang 0.2.3 or later (https://github.com/dolphlabs/slang/releases),
# git and make: the projects zokor writes are built with slangc anyway.
set -eu

REPO=https://github.com/dolphlabs/zokor_cli
MIN_SLANG=0.2.4

die() { echo "zokor install: $*" >&2; exit 1; }

command -v slangc >/dev/null 2>&1 ||
    die "slangc is not on PATH. Install slang $MIN_SLANG or later first: https://github.com/dolphlabs/slang/releases"
command -v git >/dev/null 2>&1 || die "git is required"
command -v make >/dev/null 2>&1 || die "make is required"

have=$(slangc --version 2>/dev/null | awk '{print $2}')
[ -n "$have" ] || die "cannot read slangc --version"
lowest=$(printf '%s\n%s\n' "$MIN_SLANG" "$have" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)
[ "$lowest" = "$MIN_SLANG" ] ||
    die "slang $have is too old: zokor needs $MIN_SLANG or later (https://github.com/dolphlabs/slang/releases)"

tag=${ZOKOR_CLI_VERSION:-}
if [ -n "${ZOKOR_CLI_SOURCE:-}" ]; then
    tag="the checkout at $ZOKOR_CLI_SOURCE"
elif [ -z "$tag" ]; then
    tag=$(git ls-remote --tags --refs "$REPO" 'v*' | sed 's#.*refs/tags/##' |
          sort -t. -k1.2,1n -k2,2n -k3,3n | tail -1)
fi
[ -n "$tag" ] || die "no release of zokor_cli found at $REPO"

PREFIX=${PREFIX:-$HOME/.local}
target="$PREFIX/bin/zokor"
old_version=""
if [ -x "$target" ]; then
    old_version=$("$target" version 2>/dev/null || true)
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM

if [ -n "$old_version" ]; then
    echo "zokor install: updating $target ($old_version -> $tag) with slangc $have"
else
    echo "zokor install: building zokor_cli $tag with slangc $have"
fi
if [ -n "${ZOKOR_CLI_SOURCE:-}" ]; then
    cp -R "$ZOKOR_CLI_SOURCE" "$work/zokor_cli"
    rm -rf "$work/zokor_cli/bin"
else
    git clone -q --depth 1 --branch "$tag" "$REPO" "$work/zokor_cli" ||
        die "cannot fetch $REPO at $tag"
fi
make -s -C "$work/zokor_cli" install PREFIX="$PREFIX" >"$work/build.log" 2>&1 ||
    { cat "$work/build.log" >&2; die "build failed (log above)"; }

new_version=$("$target" version 2>/dev/null || echo "$tag")
if [ -n "$old_version" ]; then
    echo "zokor install: updated $target ($old_version -> $new_version)"
else
    echo "zokor install: installed $target ($new_version)"
fi
case ":$PATH:" in
    *":$PREFIX/bin:"*) ;;
    *) echo "zokor install: add $PREFIX/bin to your PATH, e.g. export PATH=\"$PREFIX/bin:\$PATH\"" ;;
esac
echo "zokor install: start a service with: zokor new billing && cd billing && slangc get && make run"
