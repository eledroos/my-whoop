# Local fork notes — dormant-strap recovery + empty-GET_CLOCK live-HR fix

**Date:** 2026-06-02. Local changes on top of upstream `johnmiddleton12/my-whoop`,
made while reviving a WHOOP 4.0 that had been dead in a drawer ~21 months. Written
down so a reinstall or a re-freeze never costs us this knowledge or code again.

## TL;DR — what was wrong, and what fixed it

A WHOOP 4.0 dormant ~21 months had a **lost RTC** (its clock was frozen at its
last-used date, 2024-08-30). **A clock-lost strap suppresses biometric (type-47)
logging** — so it streamed live HR but recorded *no history*, and both OpenWhoop
and the **official WHOOP app** were stuck at that 2024 date.

This is **NOT** a subscription/membership gate. An expired membership is irrelevant
to the strap's *local* recording; confirmed because the official app + a firmware
update + a reboot did **not** fix it. The real gate is a valid clock.

**The fix that worked:** on connect, send `SET_CLOCK` then `REBOOT_STRAP` to
**latch** a current clock. Once the RTC is valid and the band is worn, biometric
logging resumes. Verified: the full type-47 suite (HR / R-R / SpO₂ / skin-temp /
resp / gravity) resumed, correctly dated, and the self-hosted server computed Strain.
(Notably: upstream's own debug docs had logged this exact stuck state as *unsolved* —
the latch worked here on a freshly-charged, freshly-firmware-updated band.)

## Code changes vs upstream

1. **`ios/OpenWhoop/BLE/BLEManager.swift` — clock correlation from the realtime
   stream.** This firmware answers `GET_CLOCK` with an EMPTY payload, so the normal
   correlation never fires and the live `Collector` (which gates persistence on
   `clockRef`) buffered live HR forever / mis-timestamped it (~1971). Fix: when a
   `REALTIME_DATA` frame arrives and `clockRef` is nil, derive `clockRef` from that
   frame's device timestamp paired with wall-now.

2. **`ios/OpenWhoop/BLE/{BLEManager,Commands}.swift` — stale-strap reboot-latch
   recovery.** Added `WhoopCommand.rebootStrap = 29`. In the connect handshake, a
   one-shot (`didRebootForLatch`, once per app launch) fires ~4 s after connect
   **only when the data-range looks stale** (newest record < 2025-01-01, or unknown):
   re-send `SET_CLOCK`, then `REBOOT_STRAP` to latch. The band reboots, the app
   auto-reconnects with a latched clock, and logging re-arms. The reboot is
   **non-destructive** (NOT a wipe — that would be `FORCE_TRIM`, deliberately absent).
   **To re-trigger after a future re-freeze:** relaunch the app while connected to the
   stale band (the one-shot resets each launch), or power-cycle the band.

3. **`ios/project.yml`** — unique bundle id for personal free-Apple-ID signing, plus
   `NSAppTransportSecurity` (allow LAN HTTP) + `NSLocalNetworkUsageDescription` so the
   app can reach a plain-HTTP self-hosted server on the LAN.

## Local config (NOT committed — secrets / personal)

- `ios/OpenWhoop/Config/Secrets.xcconfig` *(gitignored)* — `WHOOP_BASE_URL` (the LAN
  server, `http://<mac-ip>:8770`), `WHOOP_API_KEY`, `WHOOP_DEVICE_ID`.
- `server/.env` *(gitignored)* — `WHOOP_API_KEY` + `WHOOP_DB_PASSWORD`.
- `server/docker-compose.override.yml` — keeps Postgres + the raw archive in Docker
  named volumes (avoids macOS↔VM bind-mount issues under Colima / Docker Desktop).

## Rebuild / reinstall runbook

**iOS app**
1. `brew install xcodegen`
2. `cd ios && cp OpenWhoop/Config/Secrets.example.xcconfig OpenWhoop/Config/Secrets.xcconfig` and fill in the server URL + key (or leave placeholders for offline).
3. `xcodegen generate` → open `OpenWhoop.xcodeproj` → set the signing Team → build to a **physical iPhone** (BLE needs real hardware).

**Server** (Colima or Docker Desktop)
1. `cd server && cp .env.example .env`; set `WHOOP_API_KEY` + `WHOOP_DB_PASSWORD`.
2. `export DATA_ROOT=<dir>` then `docker compose up -d --build`. Health: `curl localhost:8770/healthz`.

## Operational notes

- **One Bluetooth central at a time** — keep the official WHOOP app **force-quit** while
  using OpenWhoop, or it grabs the band's link and OpenWhoop can't connect.
- **macOS BLE** — run any `re/` scripts from a real Terminal (Bluetooth permission); the
  custom service is encryption-gated and `bleak` writes hit "encryption insufficient" on
  macOS. The iPhone bonds cleanly, so the phone is the working path.
- **Dashboards** — Strain comes from daytime HR; **Recovery / Sleep / HRV require an
  actual sleep session** (overnight wear).
