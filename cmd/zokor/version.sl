// This CLI's own version: what `zokor version` prints, and what a release
// tag of this repository must match (.github/workflows/release.yml).
// The zokor release a new project pins is scaffold.sl's default_tag,
// kept equal to this repository's own pin in slang.project
// (tests/cli.sh checks the two agree).
fn cli_version() -> str {
    return "0.2.0";
}
