# tests/

Two live harnesses, meant to run inside an executor (or through
[roblox-mcp](https://github.com/) `execute-file` while a client is connected):

| File | What it does |
|---|---|
| `live/api-test.luau` | ~20 assertions over the public API **including regression checks for every 3.6 fix** (multi-dropdown `Set` normalization, map `Default`, `Refresh` + disabled, slider text entry, `CloseBehavior`). Always writes results to `EZTestResults.txt` in the executor workspace — even on crash. |
| `live/showcase.luau` | Full feature tour (every element + addon wiring) with a `WHEN:` comment on each — doubles as the living example. Writes `EZShowcaseResults.txt`. |

## Running

1. Connect a client (executor with `loadstring`/`HttpGet`) and execute the file.
2. Read back results: `readfile("EZTestResults.txt")` (or check the console for
   `[EZTest]` lines).

## Testing LOCAL (uncommitted) changes

The harness loads the library from the repo's `main` branch, so local edits are
not picked up until pushed. To test uncommitted changes, build a local copy and
point the harness at it:

```bash
# expose the local library on getgenv for probing (no commit needed)
sed 's/^return EZ$/getgenv().EZ_LOCAL = EZ\nreturn EZ/' Library.lua > /tmp/EZLocalBuild.luau
# execute /tmp/EZLocalBuild.luau in the client, then probe getgenv().EZ_LOCAL
```

`getgenv().EZ_LOCAL` is the live library instance — create windows/elements
against it in `get-data-by-code` probes. Re-executing the build is safe: the
getgenv teardown token destroys the previous instance first.

## CI

`.github/workflows/luau-analyze.yml` runs `luau-lsp analyze` with the
executor-environment definitions in `ci/executor.d.luau` over `Library.lua` and
every addon. It exists because the 3.6 sweep found a slider writing an
accidental global (`value`) — static analysis catches that class of bug
mechanically.
