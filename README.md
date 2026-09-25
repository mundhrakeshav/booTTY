# booTTY

booTTY is a macOS-only fork of [Ghostty](https://github.com/ghostty-org/ghostty):
Ghostty's source cut down to its macOS app. It merges upstream Ghostty now and
then.

## Building

You need:

- Xcode 26 with the macOS 26 SDK and the Metal Toolchain. Xcode 26 also runs
  on macOS 15. If the build picks up the wrong Xcode, select it with
  `sudo xcode-select --switch /Applications/Xcode.app`.
- Zig 0.16. The build accepts 0.16.0 and later 0.16 patch releases, and
  nothing newer, so `brew install zig` works only while Homebrew's `zig` is a
  0.16 release.
- nushell, for `macos/build.nu`: `brew install nushell`.

| Command                        | What it does                                                                                 |
| ------------------------------ | -------------------------------------------------------------------------------------------- |
| `zig build`                    | Builds the library and a Debug app at `zig-out/Ghostty.app`                                  |
| `zig build run`                | Builds and runs the app                                                                      |
| `zig build test`               | Runs the Zig and Swift unit tests; `-Dtest-filter=<name>` runs only the matching Zig tests   |
| `macos/build.nu`               | Builds the app with Xcode into `macos/build/<configuration>/Ghostty.app`                     |
| `macos/build.nu --action test` | Runs the Swift unit tests                                                                    |

`macos/build.nu` takes `--configuration Debug`, `Release` or `ReleaseLocal`.
After changing anything outside `macos/`, run `zig build -Demit-macos-app=false`
first, to rebuild the library the app links.

`zig build` makes Debug builds. `zig build -Doptimize=ReleaseFast` makes the
app you install, built for this Mac's architecture. For a universal app, add
`-Dxcframework-target=universal`.

## Debugging

booTTY logs to the macOS unified log:

```shell
sudo log stream --level debug --predicate 'subsystem=="com.mitchellh.ghostty"'
```

`zig build run` also logs to stderr. Everywhere else, the `GHOSTTY_LOG`
environment variable picks the destinations, `stderr` and `macos`. Combine them
with commas, turn one off with a `no-` prefix, or use `true` or `false` for all
or none. Debug-level messages appear only in Debug builds.

Before committing, format and lint what you changed:

- Zig: `zig fmt build.zig build.zig.zon src pkg`. Don't run `zig fmt .`,
  which would also rewrite the fetched packages in `zig-pkg/`.
- Swift: `swiftlint lint --strict --fix`
- Docs and resources: `prettier -w .`
- Shell scripts:
  `shellcheck --check-sourced --severity=warning $(find . \( -name "*.sh" -o -name "*.bash" \) -type f ! -path "./zig-out/*" ! -path "./zig-pkg/*" ! -path "./.zig-cache/*" ! -path "./macos/build/*" ! -path "./.git/*" | sort)`
- Spelling: `typos`

The tools come from Homebrew:
`brew install swiftlint prettier shellcheck typos-cli`.

## Where booTTY keeps its files

booTTY keeps these apart from an installed Ghostty's:

- Config: `$XDG_CONFIG_HOME/bootty/config.ghostty` (`~/.config/bootty/` by
  default) or `~/Library/Application Support/bootty/config.ghostty`.
- Themes: `$XDG_CONFIG_HOME/bootty/themes/`.
- Crash reports: `$XDG_STATE_HOME/bootty/crash` (`~/.local/state/bootty/crash`
  by default). They stay on this Mac, and nothing uploads them.

Everything tied to the bundle id is still shared with Ghostty, because booTTY
keeps `com.mitchellh.ghostty`. That covers its preferences, saved window state
and update feed. Set `auto-update = off` in booTTY's config so it doesn't offer
Ghostty's releases. The SSH terminfo cache also stays in
`$XDG_STATE_HOME/ghostty/ssh_cache`.

## Merging upstream

booTTY merges upstream Ghostty's `main` whenever it chooses, and never rebases.
Add the remote once per clone:

```shell
git remote add -t main --no-tags upstream https://github.com/ghostty-org/ghostty.git
```

Then merge:

```shell
git fetch upstream && scripts/merge-upstream
```

The script merges without committing, deletes every path listed in `.cutlist`,
runs `zig build` and `zig build test`, and commits only if both pass. It stops
when a kept file conflicts, when upstream moves a cut file somewhere `.cutlist`
doesn't cover, and when the build fails. Fix the problem, `git add`, and run it
again. Its header comment has the details.

- booTTY rewrites `README.md` and `AGENTS.md`, so upstream edits to them
  conflict. Read upstream's change, then keep booTTY's copy with
  `git checkout --ours <file> && git add <file>`.
- If the report lists a new file booTTY doesn't want, such as code for another
  platform, add its path to `.cutlist` in a follow-up commit and run
  `git rm -r --ignore-unmatch --pathspec-from-file=.cutlist`.

Never use GitHub's Sync fork button or `gh repo sync`. Neither applies
`.cutlist`, Sync fork offers to discard booTTY's commits on a conflict, and
`gh repo sync --force` resets booTTY to upstream.

## License

booTTY is Ghostty's source and keeps its MIT license. See [LICENSE](LICENSE).
