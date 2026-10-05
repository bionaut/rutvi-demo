# Vendored Synaptic source

This directory vendors Synaptic from the local checkout at the exact Git revision:

- Version: `0.3.0-alpha.13`
- Source SHA: `e98519617482f3f12801ad187cfcbc2cbd575533`
- Upstream URL recorded by its Mix project: <https://github.com/bionaut/synaptic>
- Original tracked working tree was clean at copy time.

## Copied inventory

Copied from the tracked source archive at that SHA:

- `.formatter.exs`, `.gitignore`, `mix.exs`, `mix.lock`
- `config/`, `lib/`, `priv/`, `test/`, and `docs/`
- `README.md`, `PLAN.md`, and `SECURITY.md`

This includes Synaptic's `Synaptic.Tools.CodexExec` provider and its source tests. The vendored Mix project resolves its Hex dependencies from `mix.exs` and `mix.lock`; it has no path dependency on the original developer checkout.

## Exclusions

The original Git metadata, generated `_build/`, downloaded `deps/`, generated ExDoc `doc/`, crash dump, prebuilt Hex tarballs, IDE/workspace settings, and `sidecar/` were excluded. Those are respectively repository metadata, generated/downloaded artifacts, or development integrations not needed to build this app. `publish.sh` and ad hoc `scripts/` were omitted because this app does not publish the framework and those scripts are not required to compile or test the source. No user authentication state or secret file was copied.

The original checkout contains no tracked `LICENSE`, `COPYING`, or `NOTICE` file, and no such file exists at its root. Its `mix.exs` package metadata declares `licenses: ["MIT"]`; that declaration is preserved verbatim. No license text was invented or substituted. Confirm whether upstream supplies a separate license text before redistribution beyond this repository.

Synaptic remains unmodified upstream source. Rutvi-specific behavior belongs in application modules outside this directory.
