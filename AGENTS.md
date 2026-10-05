# Repository Guidelines

## Project Structure & Module Organization

Moon extends KOReader with a Lua/LuaJIT plugin. `book.koplugin/` is the complete plugin deliverable: `book/` manages reading data, `source/` implements providers, `db/` handles SQLite, `ui/` contains desktop and reader interfaces, and `remote/html/` contains web assets. `tests/` mirrors plugin modules; shared assertions, stubs, and fixtures live under `tests/support/`. `docs/` describes module contracts and database schemas. `assets/` stores dictionary shards and manifests; `tools/` contains Python dictionary builders. `screenshots/` holds README illustrations.

## Build, Test, and Development Commands

Run commands from the repository root:

- `./tests/run.sh`: run the complete offline suite; requires `luajit` on PATH.
- `./tests/run.sh tests/book/catalog_spec.lua`: run a specific spec; multiple paths are supported.
- `./run.sh`: launch the KOReader emulator using a local `koreader/` checkout and Homebrew GNU tools. The script links the plugin into KOReader.

The plugin requires no independent compilation. Release CI runs tests, injects the version from a `v*` tag, and packages `book.koplugin/`.

## Coding Style & Naming Conventions

Follow existing Lua style: four spaces, double-quoted strings, snake_case filenames and local data fields, and camelCase methods where established. Keep code compatible with LuaJIT. Lua Language Server settings are in `.luarc.json`; VS Code recommends `sumneko.lua`. No standalone formatter or lint command is configured.

Follow `source/base.lua` and `source/registry.lua` when adding providers. Reuse `utils/text.lua`, use parameterized SQL, move expensive file/parsing work into workers, and keep database writes in the main process. Update relevant module contracts in `docs/`.

## Testing Guidelines

Use the custom runner in `tests/run.lua`, with `support.assert` and `support.stubs`. Name specs `*_spec.lua` beneath the matching module directory. Every passing spec must execute assertions. No numerical coverage threshold is configured; add focused regression cases for behavior changes. Tests default to the ignored `test/` sandbox; never point `KO_HOME` at real user data.

## Commit & Pull Request Guidelines

History uses emoji prefixes and scopes, for example `:bug: (source): fix progress sync` or `:recycle: (ui): simplify layout`. Keep commits focused. PR descriptions should explain behavior changes, link relevant issues, and list verification results. Include automated screenshots for UI changes; store verification artifacts under the canonical directory returned by `node ~/.agents/scripts/verification-dir.mjs --mkdir`.

## Security & Configuration

Keep credentials, `.env`, local runtime configuration, and `.moon/` user data out of commits. Preserve `0.0.0-dev` in the source version file; release CI supplies published versions.

## Default Release Policy

Publish a new patch release after every completed commit by default, including merge and documentation commits, unless the user explicitly requests otherwise. Finish required reviews and verification first. Increment the latest stable release's patch number (for example, `v0.1.1` → `v0.1.2`), push the commit, create an annotated tag on that commit, and push the tag to `gyh1621/moon`. Never move or reuse a published tag.

Monitor `.github/workflows/release.yml` until publishing succeeds, then verify the released plugin ZIP, injected version, and SHA256. If the tag did not trigger a run, dispatch `release.yml` with its existing `tag` input. Report the release link; do not call an unpublished or failed release complete.
