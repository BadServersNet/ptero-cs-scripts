# Pterodactyl CS2 restart monitor

This project performs only two actions for configured Pterodactyl CS2 servers:

- Restart a running server when Steam reports a newer CS2 patch.
- Restart a running server after six hours of uptime once it is empty.

Game-update restarts happen immediately, even when players are connected. Uptime restarts wait until the player-count API reports that the server is empty. Offline, starting, and stopping servers are left alone.

After a game-update restart, the monitor waits until the target patch appears in `/game/csgo/steam.inf` and Pterodactyl reports the server as running. The verification window defaults to 60 attempts at 10-second intervals and can be changed with `GAME_UPDATE_VERIFY_ATTEMPTS` and `GAME_UPDATE_VERIFY_INTERVAL_SECONDS`.

The project is self-contained. Its environment, lock, state, and logs all live inside this project and do not depend on or interfere with `update-gs-scripts`.

## Setup

The host needs Bash, `curl`, `flock`, and `jq`.

```bash
cp .env.example .env
chmod 600 .env
```

Edit `.env` and set:

- `PTERO_URL` to the panel URL.
- `PTERO_API_KEY` to a client API key with access to every configured server.
- `PTERO_SERVER_IDS` to comma-separated Pterodactyl server identifiers.

The default player-count endpoint expects the BadServers.net `/api/servers` response format and matches its server `id` values to the configured Pterodactyl identifiers. A configured server missing from a valid response is treated as empty by default. Set `PLAYER_COUNT_MISSING_IS_EMPTY=0` to treat that as an error.

Run a read-only check before enabling cron:

```bash
./restart-servers.sh --dry-run
```

## Cron

Run the check every five minutes with an absolute path:

```cron
*/5 * * * * cd /path/to/ptero-cs-scripts && ./restart-servers.sh
```

`flock` prevents overlapping runs, including while an update restart is being verified. Each run writes a UTC timestamped log beneath `.logs/`. The ignored `.cache/` directory contains this project's lock and game-update cooldown state.
