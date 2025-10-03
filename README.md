# get-aeternity installer

Convenience installer script to set up an Aeternity middleware (ae_mdw) + node using Docker Compose.

What it does:
- Optionally downloads two archives (single prompt in interactive mode) and extracts them into your data directory:
	- Node database archive (computed from NETWORK + DB_VARIANT, unless `TARBALL_URL` is provided)
	- MDW database archive (computed from NETWORK, unless `MDW_TARBALL_URL` is provided)
- Ensures `docker-compose.yml` and `aeternity.yaml` exist in `INSTALL_DIR`:
	- By default, downloads them from the official GitHub templates (env-overridable via `COMPOSE_URL` and `AETERNITY_YAML_URL`)
	- If the files already exist, they are left unchanged
	- If the remote download is not desired, local templates in `templates/` are used as fallback
- Writes a `.env` with convenient defaults for paths and runtime options
- Mounts the extracted data and `aeternity.yaml` into the container at the expected paths
- Optionally starts the container via Docker Compose

# Snapshots source

Some snapshots of databases are available at [downloads.aeternity.io](https://downloads.aeternity.io)

# Warning
- Significant amount of disk space is required (1TB SSD is recommended)
- If you want to sync the blockchain from 0, be aware that it might take days to finish
- Node is not configured for mining (additional setup is required for that)

## Prerequisites
- Docker with Compose plugin (`docker compose`) or `docker-compose`
- `curl` or `wget`
- `tar` with zstd support or `unzstd` from the `zstd` package

## Usage

Interactive (prompts):
```
./get-aeternity.sh
```

Flow in interactive mode:
- If `NETWORK` is not provided via env, you'll be asked to choose it first
- The script probes the (computed or overridden) snapshot URLs for their compressed sizes and shows:
	- Individual node + MDW archive sizes
	- Combined size and a recommended free space = 2.5x compressed total
- You'll be asked once whether to download both snapshots (node + MDW)
- If you answer No you can supply local existing `.tar.zst` archive paths for node and/or MDW instead of downloading
- If no tarball URLs are provided via env, they are computed from the chosen `NETWORK` (and `DB_VARIANT` for the node)

Non-interactive (via ENV):
```
NETWORK=mainnet \
# Optional overrides (uncomment as needed):
# INSTALL_DIR=$PWD/aeternity-node \
# DOWNLOAD_NODE_DB=false \
# DOWNLOAD_MDW_DB=false \
# DB_VARIANT=light \
# TARBALL_URL=https://example.com/custom-node.tar.zst \
# MDW_TARBALL_URL=https://example.com/custom-mdw.tar.zst \
# AETERNITY_YAML_URL=https://raw.githubusercontent.com/aeternity/get-aeternity/main/templates/aeternity.yaml \
# COMPOSE_URL=https://raw.githubusercontent.com/aeternity/get-aeternity/main/templates/docker-compose.yml \
./get-aeternity.sh --yes --no-start
```

Flags:
- `-y|--yes|--non-interactive` Run without prompts, using ENV/defaults
- `--no-start` Do not start the service after setup
- `--dry-run` Show what would be done without downloading, extracting, writing files, or starting services
- `-h|--help` Show help

Environment variables (optional unless noted):
- `NETWORK` Network to support: `mainnet` or `testnet`/`uat` (default: `mainnet`)
- `DB_VARIANT` Database variant: `full` or `light` (default: `full`; env-only, no prompt)
- `DOWNLOAD_NODE_DB` If `false`, skip node DB download/extract (default: `true`)
- `DOWNLOAD_MDW_DB` If `false`, skip MDW DB download/extract (default: `true`)
- `INSTALL_DIR` Local install directory (default: current working directory)
- `TARBALL_URL` Custom URL to the node `.tar.zst` archive (optional). If not provided, it's computed from `NETWORK` + `DB_VARIANT`.
- `MDW_TARBALL_URL` Custom URL to the MDW `.tar.zst` archive (optional). If not provided, it's computed from `NETWORK`.
- For both `TARBALL_URL` and `MDW_TARBALL_URL`, if you set them to a local file path (no `http(s)` / `s3://` prefix), the script will not download and will directly extract that archive.
- `AETERNITY_YAML_URL` URL to `aeternity.yaml` (optional; if omitted defaults to the official GitHub template)
- `COMPOSE_URL` URL to `docker-compose.yml` (optional; if omitted defaults to the official GitHub template)
- `.env` file will include: `HOST_DATA_ROOT`, `HOST_APP_ROOT`, `ELIXIR_ERL_OPTIONS`, `LOG_FILE_PATH`

## After install
To manage the service:
```
(cd INSTALL_DIR && docker compose ps)
(cd INSTALL_DIR && docker compose logs -f)
(cd INSTALL_DIR && docker compose down)
```
If you use `docker-compose` binary, replace `docker compose` with `docker-compose`.

## Notes
- `.env` includes the env for the running container, while the other env vars are for the installer
- `DB_VARIANT=light` is not recommended as it might cause unexpected issues, mdw requires the full database
- The script writes files into `INSTALL_DIR`: `docker-compose.yml`, `.env`, and `downloads/` (and uses `templates/` as fallback for config files).
- Data and config are organized under:
	- `INSTALL_DIR/data/<network>/mnesia` and `INSTALL_DIR/data/<network>/mdw.db` (NODE and MDW snapshot contents extracted under `data/<network>`)
	- `INSTALL_DIR/app/<network>/aeternity.yaml` and `INSTALL_DIR/app/<network>/log`
- If your `tar` doesn't support zstd, ensure `unzstd` is installed (`zstd` package).
- If you restore from a snapshot it might take a while to sync to the latest block.
- When declining downloads in interactive mode, you can provide local snapshot paths for extraction.
- The script estimates required space (2.5x combined compressed size) but does not yet automatically check free disk space.
- `--dry-run` can be used to review actions and computed URLs (including size probe) without making any changes.
