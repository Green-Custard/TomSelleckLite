# Tom Selleck Lite

Runs Claude Code as a sandboxed coding agent ("Tom Selleck Lite") inside a devcontainer, with its own Gitea server and its own Docker.

- **Sandbox:** the devcontainer runs under the [Sysbox](https://github.com/nestybox/sysbox) runtime. The agent can run Docker inside it without `--privileged` and without the host's Docker socket. Root inside the container maps to an unprivileged user on the host.
- **Network:** a firewall (`.devcontainer/init-firewall.sh`) limits the agent to an allowlist: GitHub, npm, the Anthropic API, and Gitea plus the Docker Hub cache on the host.
- **Gitea:** a private Git server on the host at <http://localhost:8099>, where the agent pushes its work.
- **Docker inside the sandbox:** pulls go through a Docker Hub cache on the host (`registry-cache`). The agent can reach the services it starts.
- **Playwright:** `playwright-cli` and the Playwright test runner, with Chromium and (on amd64) Google Chrome preinstalled.

## Supported operating systems

| Host | Supported |
|---|---|
| **Ubuntu** (x86_64 / arm64) | Yes. Tested on Ubuntu 24.04, kernel 6.8. |
| **Debian** (x86_64 / arm64) | Should work: Sysbox ships `.deb` packages and `install-sysbox.sh` handles them. Untested. |
| **Other Linux distros** | Only if you build and install Sysbox from source (see Sysbox's distro compatibility docs). `install-sysbox.sh` won't do it. |
| **macOS, Windows** | No. Sysbox needs a Linux host running Docker Engine directly. |
| **Docker Desktop** (any OS, including Docker Desktop for Linux) | No. It runs Docker in a VM, which can't use Sysbox. |
| **WSL2** | Untested. |

On arm64, Google Chrome isn't available, so only Chromium is installed. `playwright-cli` opens Chrome by default, so pass `--browser=chromium` there.

## Required software

On the host:

| Software | Why | Notes |
|---|---|---|
| Linux kernel **5.12 or newer** | Sysbox uses ID-mapped mounts so files in `Projects/` keep your ownership | Older kernels need the `shiftfs` module |
| **systemd** | Runs the Sysbox services | |
| **Docker Engine** | Runs everything | Docker CE or your distro's `docker.io`. Not Docker Desktop, not rootless Docker. Your user must be in the `docker` group. Tested with 29.7. |
| **Docker Compose v2** (`docker compose`) | Runs Gitea and the registry cache | Tested with v5.4 |
| **Sysbox CE 0.7.1** | The container runtime for the sandbox | Install with `./install-sysbox.sh` |
| **Node.js and npm** | For the devcontainer CLI | Tested with Node 24 |
| **devcontainer CLI** | `tsl` uses it to build and enter the container | `npm install -g @devcontainers/cli`. Tested with 0.90. |
| **bash, curl, git, sudo** | Used by the scripts | `install-sysbox.sh` installs `jq` if it's missing |

You also need:

- **A Claude account.** On first start, log in to Claude Code inside the container; the login is kept in a Docker volume. `./tsl` turns on Remote Control, which needs a claude.ai subscription login.
- **Free ports:**
  - `8099` on all interfaces, for Gitea.
  - `5000` on the Docker bridge (`172.17.0.1`), for the registry cache.
- **Docker's default bridge at `172.17.0.1`,** which is Docker's default. The registry cache binds to that address.
- **Internet access** while building the image and pulling images, and a few GB of disk for the image (Docker, Chrome, Chromium).

## Setup

```bash
./install-sysbox.sh   # once, installs Sysbox (needs sudo)
./tsl rebuild         # build the devcontainer
./tsl                 # start everything and open the agent's Claude session
```

### What `install-sysbox.sh` does

It downloads Sysbox 0.7.1, checks the checksum, and installs it without restarting Docker or touching any containers.

Before installing, it writes Docker's current `bip` and `default-address-pools` into `/etc/docker/daemon.json`, after backing up any existing file. Without those, the Sysbox installer refuses to run while any container exists. It would then switch Docker to subnets that can clash with existing compose networks, and restart Docker.

### First start

On the first `./tsl`, `./gitea up` finds no Gitea users and runs `./gitea-onboard`. It asks you to choose a password for the `host` admin account. It then creates:

| Gitea account | Role |
|---|---|
| `host` | Admin. Your password, never stored. |
| `agent` / `agent` | Not an admin. The sandboxed agent's account. |
| `host-org` | A private organisation. The agent has no access to it. |

Forgot the `host` password? Run `./gitea-onboard reset-host`.

## Commands

| Command | What it does |
|---|---|
| `./tsl` | Start Gitea, the cache and the container, then resume the "TomSelleckLite" Claude session (or create it) with Remote Control |
| `./tsl new` | Start a fresh session even if one exists |
| `./tsl shell` | Open a shell in the container |
| `./tsl rebuild` | Rebuild the container. Logins, sessions and pulled images are kept. Needed after any change in `.devcontainer/`. |
| `./tsl stop` | Stop the container, Gitea and the cache |
| `./gitea up\|stop\|logs\|status` | Manage Gitea and the registry cache (`compose.gitea.yml`) |
| `./gitea-onboard` | Create missing Gitea users and the org (safe to re-run) |
| `./gitea-onboard reset-host` | Set a new password for `host` |

## Files

| Path | Purpose |
|---|---|
| `CLAUDE.md` | Instructions: a section for the host agent and one for the sandboxed agent |
| `commit-user.txt` | Name and email the sandboxed agent uses for commits |
| `Projects/` | The agent's projects. The only writable folder inside the container; git-ignored here. |
| `.devcontainer/` | Image, container settings, firewall and Docker startup |
| `compose.gitea.yml` | Gitea and the Docker Hub cache |

## How the sandbox is isolated

- **Workspace:** inside the container, the project folder is mounted read-only, except `Projects/`. The agent can't change `tsl`, the firewall, `CLAUDE.md`, `.git` or anything else you run on the host.
- **Host:** Sysbox maps the container's root to an unprivileged host user, and the host Docker socket isn't mounted.
- **Network:**
  - The agent (`node`) can only reach allowlisted hosts.
  - Root inside the container (the inner Docker) may make HTTPS connections, so image pulls from any registry work.
  - Containers the agent starts with Docker have unrestricted internet.
  - On the host, only Gitea (8099) and the registry cache (5000) are reachable.

The firewall only stops the agent's own direct connections. Anything that can use Docker is effectively root inside the container, so the agent could route around the allowlist through a container. If you need hard network limits, enforce them on the host, outside the container.

## Known issues

- **Gitea's address inside the container:** `localhost:8099` there is the container itself, so the agent reaches Gitea at `172.17.0.1:8099`, the host's Docker bridge.
- **Re-applying the firewall restarts the inner Docker:** applying the firewall wipes Docker's network rules, so `tsl` restarts the inner Docker afterwards. That stops any containers the agent was running.
