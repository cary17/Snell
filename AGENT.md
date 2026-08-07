# Snell Agent Interface

## 0. Source And Entry Points

Repository: <https://github.com/cary17/Snell>

Installer source:

```text
https://raw.githubusercontent.com/cary17/Snell/main/Snell.sh
```

Agent manual:

```text
https://raw.githubusercontent.com/cary17/Snell/main/AGENT.md
```

Download:

```bash
curl -fsSL https://raw.githubusercontent.com/cary17/Snell/main/Snell.sh -o Snell.sh
chmod 700 Snell.sh
```

The installer has two user modes:

- Human mode: `bash Snell.sh` opens the TUI.
- Agent mode: use `--agent-*` commands. Do not simulate TUI input.

The agent should read this file first. The script also prints the compact contract with:

```bash
bash Snell.sh --agent-help
```

The examples below use `v5.0.1`; replace it with a supported version after checking the matrix.

## 1. Safety And Side Effects

1. Run `--dry-run` before any real install or reconfiguration.
2. `--dry-run` only validates and prints generated files. It does not pull images, write `/etc/snell`, write `/opt/snell`, start services, stop services, create containers, or remove containers.
3. Real installation and service operations require root.
4. `PSK` is a secret. Prefer `--config-stdin` or a temporary mode-600 config file over putting it in shell history.
5. `--yes` is required for agent operations that can change an existing installation: reconfigure, update, and uninstall. `--agent-uninstall --yes` is destructive.
6. After a real successful install or reconfiguration, the script prints a **Snell 已生效配置** block containing the exact active configuration. This block does not include install method or config-file paths.
7. Agent-mode install/reconfiguration additionally prints a separate **Agent 安装信息** block containing the install method and persistent configuration path.
8. Normal Docker restart uses `docker compose restart` and does not create a new container.
9. Docker configuration or version changes use `docker compose down --remove-orphans` followed by `up -d --remove-orphans`.
10. A mounted `/snell/snell.conf` has highest runtime priority. The entrypoint uses it as-is, does not generate from environment variables, and does not modify the mounted file; read-only mounts are supported.
10. Native configuration changes rewrite `/etc/snell/snell.conf` and restart the service.
11. The installer does not run global `docker prune`.
12. A pre-existing container named `snell` that is not managed by this installer is not adopted or migrated; the operation fails and leaves it untouched.

## 2. Supported Versions

The repository currently records these versions:

| Version | Release family | Native | Docker | Relevant configuration family |
|---|---|---:|---:|---|
| `v3.0.1` | v3 | yes on glibc Linux | yes | LISTEN, PSK, IPV6, OBFS/HOST |
| `v4.0.0` | v4.0 | yes on glibc Linux | yes | LISTEN, PSK, IPV6, OBFS/HOST |
| `v4.0.1` | v4.0 | yes on glibc Linux | yes | LISTEN, PSK, IPV6, OBFS/HOST |
| `v4.1.0` | v4.1 | yes on glibc Linux | yes | LISTEN, PSK, IPV6, DNS, OBFS/HOST |
| `v4.1.1` | v4.1 | yes on glibc Linux | yes | LISTEN, PSK, IPV6, DNS, OBFS/HOST |
| `v5.0.0` | v5 | yes on glibc Linux | yes | LISTEN, PSK, IPV6, DNS, EGRESS_INTERFACE, OBFS/HOST |
| `v5.0.1` | v5 | yes on glibc Linux | yes | LISTEN, PSK, IPV6, DNS, EGRESS_INTERFACE, OBFS/HOST |
| `v6.0.0b2` | v6 beta | yes on glibc Linux | yes | LISTEN, PSK, IPV6 (explicit/derived), DNS, DNS_IP_PREFERENCE, EGRESS_INTERFACE, MODE |
| `v6.0.0b3` | v6 beta | yes on glibc Linux | yes | LISTEN, PSK, IPV6 (explicit/derived), DNS, DNS_IP_PREFERENCE, EGRESS_INTERFACE, MODE |
| `v6.0.0b4` | v6 beta | yes on glibc Linux | yes | LISTEN, PSK, IPV6 (explicit/derived), DNS, DNS_IP_PREFERENCE, EGRESS_INTERFACE, MODE |
| `v6.0.0rc` | v6 release candidate | yes on glibc Linux | yes | LISTEN, PSK, IPV6 (explicit/derived), DNS, DNS_IP_PREFERENCE, EGRESS_INTERFACE, MODE |

`latest` and major Docker tags such as `v6` are valid for Docker only. Native installation requires a complete version such as `v5.0.1`.

Native installation means the official release binary. It requires a glibc-based Linux environment. Alpine/musl cannot execute the official native binary reliably.

## 3. Version Configuration Matrix

The following is the installer/runtime contract. A field marked `no` must not be supplied to the agent for that version; the script rejects explicitly supplied unsupported fields instead of silently pretending to apply them.

| Field | v3.0.1 | v4.0.x | v4.1.x | v5.x | v6.x |
|---|---:|---:|---:|---:|---:|
| `LISTEN` | yes | yes | yes | yes | yes |
| `PSK` | yes | yes | yes | yes | yes |
| `IPV6` | yes | yes | yes | yes | explicit/derived |
| `DNS` | no | no | yes | yes | yes |
| `DNS_IP_PREFERENCE` | no | no | no | no | yes |
| `EGRESS_INTERFACE` | no | no | no | yes | yes |
| `OBFS` / `HOST` | yes | yes | yes | yes | no |
| `MODE` | no | no | no | no | yes |

### 3.1 LISTEN

- Agent key/environment name: `PORT` or `LISTEN`.
- Agent CLI flag: `--port PORT`.
- Valid single port range: `10000-65535`.
- In native mode the current installer accepts one numeric port and generates:
  - v3-v5: `listen = :::PORT`
  - v6+: `listen = 0.0.0.0:PORT, [::]:PORT`
- Docker host mode uses the same port without a host port mapping.
- Docker bridge mode maps `PORT:PORT`.
- The installer rejects a port already in use.
- v6 runtime supports multiple listen endpoints, but the Agent CLI currently uses one numeric port for a predictable host/bridge mapping. Do not pass comma-separated ports to `--port`.

### 3.2 PSK

- Agent key/environment name: `PSK`.
- Agent CLI flag: `--psk VALUE`.
- Required length: **16-180 bytes, inclusive**.
- Validation is by byte length, not Unicode character count.
- Allowed characters: ASCII letters, digits, `.`, `_`, `+`, `=`, `/`, `-`.
- Spaces, quotes, `#`, `:`, backslashes, newlines and non-ASCII characters are rejected by the installer contract.
- It is required for all versions. If omitted in human TUI mode, the installer generates a random value.

### 3.3 IPV6

- Agent key/environment name: `IPV6`.
- Agent CLI flag: `--ipv6 true|false`.
- Direct agent input is supported by v3+; v6+ resolves conflicts with `DNS_IP_PREFERENCE` before persisting Docker configuration.
- Docker runtime input also accepts `IPV6=true|false` for v6+.
- Allowed values: `true` or `false`.
- Default for v3-v5: `false`.
- For Docker v6+, `DNS_IP_PREFERENCE` determines the final `ipv6` value:
  - `prefer-ipv4` / `ipv4-only` -> `ipv6 = false`
  - `prefer-ipv6` / `ipv6-only` -> `ipv6 = true`
  - If an explicit `IPV6` conflicts, `Snell.sh` resolves it before writing `.env`/Compose: option `1` resubmits non-conflicting values; option `2` applies the `DNS_IP_PREFERENCE` value. The entire prompt has one 30-second deadline; timeout or EOF defaults to `2`.
  - Values submitted through option `1` must be non-conflicting before they replace the current values.
  - `default` or unset preserves explicit `IPV6`; if both are unset, omit both `dns-ip-preference` and `ipv6`.
- Agent conflict policy is `prompt`, `resubmit`, or `auto`; the prompt uses one 30-second total deadline. Final Docker values are written to `.env` before container creation. Direct container startup does not resolve conflicts: it warns and preserves both valid values. Unknown environment variables are ignored; invalid runtime values for known fields warn and fall back to defaults or omit the optional field. Agent input remains strict and rejects invalid values before persistence.

### 3.4 DNS

- Agent key/environment name: `DNS`.
- Agent CLI flag: `--dns 'SERVER1, SERVER2'`.
- Supported from v4.1 onward: `v4.1.0`, `v4.1.1`, v5.x and v6.x.
- Unsupported by v3 and v4.0.x.
- Optional. Empty means the runtime/default behavior is used.
- Installer accepted characters are addresses, commas, spaces, underscores, dots, colons and hyphens.
- Examples:

```text
DNS=1.1.1.1, 8.8.8.8
DNS=1.1.1.1, 8.8.8.8, 2001:4860:4860::8888
```

### 3.5 DNS_IP_PREFERENCE

- Agent key/environment name: `DNS_IP_PREFERENCE`.
- Agent CLI flag: `--dns-ip-preference VALUE`.
- Supported only by v6.x.
- Allowed values:
  - `default`
  - `prefer-ipv4`
  - `prefer-ipv6`
  - `ipv4-only`
  - `ipv6-only`
- Do not supply it to v3-v5.

### 3.6 EGRESS_INTERFACE

- Agent key/environment name: `EGRESS_INTERFACE`.
- Agent CLI flag: `--egress-interface NAME`.
- Supported from v5 onward.
- Optional; empty disables the setting.
- Allowed interface name characters: ASCII letters, digits, `_`, `.`, `-`.
- Example: `EGRESS_INTERFACE=eth0`.
- In Docker bridge mode the container network controls egress; the setting may not refer to a host interface inside the container. Host mode is preferred when host-interface egress is required.

### 3.7 OBFS and HOST

- Agent key/environment names: `OBFS`, `HOST`.
- Agent CLI flags: `--obfs VALUE`, `--host DOMAIN`.
- Supported only by v3-v5. v6+ rejects both fields and uses `MODE` instead.
- v3 allowed `OBFS` values: `none`, `http`, `tls`.
- v4-v5 allowed `OBFS` values: `none`, `http`.
- If `OBFS` is `http` or `tls`, `HOST` is required.
- If `OBFS=none`, `HOST` must be empty.
- `HOST` allowed characters: ASCII letters, digits, dots and hyphens.
- Example:

```text
OBFS=http
HOST=www.example.com
```

### 3.8 MODE

- Agent key/environment name: `MODE`.
- Agent CLI flag: `--mode VALUE`.
- Supported only by v6.x.
- Allowed values: `default`, `unshaped`, `unsafe-raw`.
- Do not supply it to v3-v5.

### 3.9 LOGLEVEL

- Agent key/environment name: `LOGLEVEL`.
- Agent CLI flag: `--loglevel VALUE`.
- Optional. If omitted, do not pass `-l`; Snell uses its built-in default level.
- Supported by all recorded versions from v3.0.1 through v6.0.0rc.
- Allowed values: `trace`, `verbose`, `info`, `notify`, `warning`, `error`.
- Values are case-sensitive.
- Native mode stores the value outside `snell.conf` and adds `-l VALUE` to the service command.
- Docker mode stores the value in `/opt/snell/.env`; the image entrypoint adds `-l VALUE`.
- Do not write `log = VALUE` into `snell.conf`.

## 4. Configuration Input Methods

Configuration file is optional. Command-line values are sufficient.

### 4.1 Direct CLI Values

```bash
bash Snell.sh --agent-install \
  --method docker \
  --version v5.0.1 \
  --network host \
  --registry auto \
  --port 20000 \
  --psk 'replace-with-16-to-180-safe-bytes' \
  --dns '1.1.1.1, 8.8.8.8' \
  --dry-run
```

Remove `--dry-run` only after inspecting the generated output.

### 4.2 Standard Input

```bash
printf '%s\n' \
  'PORT=20000' \
  'PSK=replace-with-16-to-180-safe-bytes' \
  'DNS=1.1.1.1, 8.8.8.8' \
  | bash Snell.sh --agent-install --method docker --version v5.0.1 --config-stdin --dry-run
```

### 4.3 Config File

The file is plain `KEY=VALUE`, not shell code. Unknown keys are rejected. Use mode `600`.

```text
METHOD=docker
VERSION=v5.0.1
NETWORK=host
REGISTRY=auto
PORT=20000
PSK=replace-with-16-to-180-safe-bytes
DNS=1.1.1.1, 8.8.8.8
LOGLEVEL=info
```

```bash
chmod 600 snell.agent.conf
bash Snell.sh --agent-install --config-file ./snell.agent.conf --dry-run
```

Command-line flags override values read from the config file or stdin.

## 5. Agent Commands For Every TUI Function

### Install

```bash
bash Snell.sh --agent-install ... --dry-run
bash Snell.sh --agent-install ...
```

Required for installation:

- `--method native|docker`
- `--version VERSION`
- `--port PORT`
- `--psk PSK`

Docker-only selection:

- `--network host|bridge`, default `host`
- `--registry auto|ghcr|dockerhub`, default `auto`

### View Configuration

Equivalent to the TUI “查看配置” action:

```bash
bash Snell.sh --agent-config
```

This prints native `/etc/snell/snell.conf`, or Docker `.env`/container configuration. It is read-only and does not require `--yes`.

### View Status

Equivalent to “查看状态”:

```bash
bash Snell.sh --agent-status
```

Native status uses systemd/OpenRC and Docker status uses Compose plus recent container logs.

### Start, Stop, Restart

Equivalent to the three service actions:

```bash
bash Snell.sh --agent-start --yes
bash Snell.sh --agent-stop --yes
bash Snell.sh --agent-restart --yes
```

The explicit `--yes` prevents an agent from changing a live service accidentally.

- Native: service manager operation.
- Docker start: starts the existing Compose service.
- Docker stop: stops the existing container.
- Docker restart: uses `compose restart`; it does not recreate the container.

### Reconfigure

Equivalent to “修改配置”. Only supplied fields change; omitted fields are read from the current installation.

```bash
bash Snell.sh --agent-reconfigure --port 20001 --yes --dry-run
bash Snell.sh --agent-reconfigure --port 20001 --yes
```

For Docker, configuration changes recreate the container. For native, the config file is rewritten and the service is restarted.

`--agent-reconfigure` cannot change installation method, version, or Docker network mode. Use a fresh install/update path for those changes.

### Update

Equivalent to “更新”:

```bash
bash Snell.sh --agent-update --yes
```

- Native: downloads the latest detected release, starts it, and rolls back on startup failure.
- Docker: pulls the configured image and applies it with Compose.
- The update may access the network and may replace the running artifact.

### Uninstall

Equivalent to “卸载”:

```bash
bash Snell.sh --agent-uninstall --yes
```

This removes the managed native service/binary/configuration or Docker Compose directory/container/image and the installer state. It does not perform global Docker cleanup.

## 6. Alpine/musl Behavior

The official Snell native binary cannot run reliably on Alpine/musl. Do not install third-party glibc packages for this purpose.

Interactive TUI behavior:

- Select native installation.
- The script asks whether to switch to Docker.
- Yes: reuses the selected version/configuration and continues with Docker network/registry selection.
- No: exits without downloading the native binary or creating native files.

Agent behavior:

```bash
# Explicitly switch native request to Docker on Alpine
bash Snell.sh --agent-install \
  --method native \
  --version v5.0.1 \
  --port 20000 \
  --psk 'replace-with-16-to-180-safe-bytes' \
  --alpine-fallback docker \
  --dry-run
```

Without `--alpine-fallback docker`, the agent command fails clearly and leaves the host unchanged.

## 7. Installation Persistence

Native:

- Config: `/etc/snell/snell.conf`
- Binary: `/usr/local/bin/snell-server`
- systemd unit: `/etc/systemd/system/snell.service`
- OpenRC unit: `/etc/init.d/snell`
- State: `/var/lib/snell/install-mode`

Docker:

- Directory: `/opt/snell`
- Fixed environment: `/opt/snell/.env`
- Compose file: `/opt/snell/docker-compose.yml`
- State: `/var/lib/snell/install-mode`
- No host `snell.conf` bind mount is used.

## 8. Exit And Failure Interpretation

- `0`: requested operation completed, or dry-run completed.
- `1`: validation failure, missing installation, dependency failure, download failure, service failure or container failure.
- `2`: invalid agent command, missing required argument, or missing confirmation such as `--yes`.

An unsupported version/configuration combination is a validation failure and should be corrected by the agent before retrying. A failed image pull or binary download is an external/network failure, not evidence that the configuration syntax is wrong.

## 9. Minimal Agent Workflow

```bash
# 1. Download the script and this manual
curl -fsSL https://raw.githubusercontent.com/cary17/Snell/main/Snell.sh -o Snell.sh
curl -fsSL https://raw.githubusercontent.com/cary17/Snell/main/AGENT.md -o AGENT.md
chmod 700 Snell.sh

# 2. Validate the requested version and configuration without side effects
bash Snell.sh --agent-install \
  --method docker --version v5.0.1 --network host \
  --port 20000 --psk 'replace-with-16-to-180-safe-bytes' \
  --dry-run

# 3. Execute only after the dry-run output is acceptable
bash Snell.sh --agent-install \
  --method docker --version v5.0.1 --network host \
  --port 20000 --psk 'replace-with-16-to-180-safe-bytes'

# 4. Verify
bash Snell.sh --agent-status
bash Snell.sh --agent-config
```
