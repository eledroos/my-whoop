# Feasibility: an Android OpenWhoop client for the WHOOP 4.0

**Date:** 2026-06-03. Question: how hard would it be to build an **Android** app that reads the
user's **owned, working WHOOP 4.0** over BLE and feeds the **existing** self-hosted server
(FastAPI + TimescaleDB)? (No goose / no 5.0 — same band, same server, new platform.)

Method: a multi-agent pass — 2 code agents (what-must-Android-replicate + decode portability) +
2 web agents (Android BLE mechanics + prior art) → synthesis → adversarial review. The review
found the first synthesis **too optimistic** on four points; **this doc is the corrected version.**
Claims tagged **[CODE]** (confirmed in OpenWhoop/server source), **[COMMUNITY]** (web/RE claim),
**[INFERENCE]**.

---

## TL;DR — corrected verdict

**Difficulty: Moderate-to-Hard, gated by two things, not one.** The *protocol* side is genuinely
easy and de-risked: the gen4 wire format is data-driven and already triple-implemented (Python,
Swift, Rust-reference), the decoder is small and well-fixtured, and the server REST contract is
reusable verbatim. The hard part is Android BLE platform engineering — and two items are real gates:

1. **[GATE #1 — genuinely uncertain] Will a *third-party* Android app bond with the 4.0?** We know
   the band bonds with the *official* WHOOP Android app and with the iPhone, and the bond is generic
   Just-Works keyed on one confirmed encrypted write. But **no public prior art shows a from-scratch
   Android `BluetoothGatt` client completing that bond** — the only Android-vs-this-band attempt in
   the evidence was a packet *sniffer* that got stuck on the checksum and never built a working
   reader. Authoritative BLE sources even disagree on whether Android auto-initiates pairing on
   encrypted-attribute access. **Treat this as a coin-flip-risk go/no-go, not a near-certainty.**
   [COMMUNITY/INFERENCE]
2. **[GATE #2 — conditional blocker] Background reliability / Doze.** The whole metric pipeline
   depends on a ~15-min periodic offload that only runs *while connected*. Android 12+ forbids
   starting a foreground service from the background, and Doze/process-death drop the link. The
   Nordic BLE library does **not** solve this layer. Whether it's a blocker depends on whether you
   accept a permanently-foregrounded collector with a persistent notification. [COMMUNITY/INFERENCE]

**The good news:** unlike the 5.0 question, this is **fully testable** — you own the band. And the
cheapest possible experiment (a throwaway app that does one write) resolves Gate #1 before any real
investment. **Smallest first milestone = prove the bond.**

---

## What an Android app must replicate (all [CODE], confirmed in the iOS app + server)

1. **Scan + connect** — scan by service UUID `61080001-8d6d-82b8-614a-1c8cb0f8dcc6` only (no name
   filter); on discover, stop scan, connect `TRANSPORT_LE`, discover the custom service + `180D` (HR)
   + `180F` (battery).
2. **Bond trigger ("the bonding trick")** — on discovering CMD-write char `61080002`, issue **one
   confirmed (with-response) write** of `GET_BATTERY_LEVEL` (opcode 26, payload `[0x00]`). Write
   completing without error = bonded. The custom notify channels (`…0003/04/05`) only flow after this.
3. **Enable notifications** — CCCD-enable notify on `61080003` (cmd responses), `61080004` (events),
   `61080005` (data), plus standard `2A37`/`2A19`.
4. **Connect handshake** (once per connection): `GET_HELLO_HARVARD`(35) → `GET_ADVERTISING_NAME`(76)
   → `SET_CLOCK`(10, 8-byte payload) → `GET_CLOCK`(11, empty) → `R10/R11 Realtime`(63, stops the
   type-43 flood) → `GET_DATA_RANGE`(34); ~1.5s later `SEND_HISTORICAL_DATA`(22, payload `[0x00]`,
   with-response). (The shipping app does **not** enter high-freq sync — it sends `EXIT_HIGH_FREQ_SYNC`
   defensively.)
5. **Frame reassembly + CRC** — buffer notification fragments, scan to `0xAA` SOF, read len u16 LE,
   frame = len+4 bytes; verify CRC8 (poly 0x07) + CRC32 (zlib).
6. **Offload ack loop** — on each `HISTORY_END` (type-49, meta_type 2), write `HISTORICAL_DATA_RESULT`
   (23, with-response, payload `[0x01] + end_data[8]`) to advance the trim cursor; without it the
   offload stalls.
7. **Decode type-47 V24** → 8 streams (hr, rr, spo2, skin_temp, resp, gravity, events, battery).
8. **Upload** — `POST /v1/ingest-decoded`, Bearer auth, one POST per stream kind; mark synced only on
   HTTP 2xx.
9. **Lifecycle** — ~900s backfill re-trigger, ~30s upload timer, 60s idle watchdog, reconnect on
   disconnect, persisted sync watermark.

---

## The architecture fork

**Critical fact [CODE]:** the server's raw `/v1/ingest` path does **not** decode type-47 history —
`process_batch` runs `extract_streams` (live type-40/43/48 → hr/rr/events/battery only). The
function that decodes type-47 into all 6 biometric streams (`extract_historical_streams`) is
**unexported and test-only**. So a naïve "upload raw, server decodes" client would silently get
**zero** biometric history rows.

| | **Option A — Thin** (Android = transport, server decodes) | **Option B — Full** (Android decodes in Kotlin) ✅ recommended |
|---|---|---|
| Android work | BLE + handshake + reassembly + raw batch upload to `/v1/ingest` | + a Kotlin type-47 decoder, upload decoded to `/v1/ingest-decoded` |
| Server change | **S–M** (not "5–10 lines"): export `extract_historical_streams`, detect+route type-47 in `process_batch`, **merge** historical+live stream sets, reconcile clock-ref, add tests for a path no prod code exercises | **None** — reuses the exact iOS contract |
| Downside | Two live-ingest paths to maintain; an unproven prod server path; higher bandwidth | Must hand-write + parity-test a Kotlin decoder |
| Effort | Android M, Server S–M | Decode **S–M** (~1 week, byte-parity), no server work |

**Recommendation: Option B.** The decoder is small and well-fixtured, so A's only advantage
("skip the decoder") is worth ~a week — while A forces an unproven second server path. B reuses the
iOS server contract with **zero** server change. [INFERENCE from CODE]

---

## Android-platform deltas vs iOS CoreBluetooth

| Concern | Android vs iOS | Verdict |
|---|---|---|
| **Bonding trigger** | iOS auto-pairs transparently on the encrypted write. Android's stack *may* auto-initiate Just-Works SMP — but sources disagree, and OEM/version behavior varies. | **Genuinely uncertain (Gate #1).** Handle both: watch `ACTION_BOND_STATE_CHANGED`; on Android 6/7 retry the write after `BOND_BONDED` (first write fails). |
| **Encryption errors** | iOS hides them. Android may surface `GATT_INSUFFICIENT_ENCRYPTION`(0x0F)/`AUTHENTICATION`(0x05). | Harder — code the error→bond→retry path. |
| **Permissions** | iOS: one Bluetooth permission. Android 12+: runtime `BLUETOOTH_SCAN`(+`neverForLocation`)+`BLUETOOTH_CONNECT`; ≤11 needs `ACCESS_FINE_LOCATION`. | Harder boilerplate, deterministic. |
| **Background keep-alive** | iOS: CoreBluetooth state restoration. Android: **foreground service** (`connectedDevice`, persistent notification); Android 12+ **can't start FGS from background** → cold reconnect needs a `PendingIntent`-woken path. | **Harder (Gate #2).** |
| **Reconnection** | iOS auto-rescans 3s after drop. Android: `autoConnect=true` for known devices; initial connect `false` (fast, ~30s timeout → **status 133**). | Harder — needs discipline. |
| **GATT op discipline** | iOS serializes. Android: one outstanding op at a time (command queue); **deep-copy** notification buffers (Android reuses them — a 96-byte data stream loses data otherwise). | Harder — but Nordic handles it. |
| **MTU** | iOS implicit. Android default 23 (20 usable) → `requestMtu()` early. | Tuning step. |

**Net:** nothing is *easier* on Android; several things are harder; bonding-on-a-custom-service is
the one genuinely uncertain item. None of it is novel — it's the standard Android BLE pain surface,
mostly absorbed by the Nordic Android-BLE-Library (queue, 133, bonding callbacks) — **except** the
OS-level Doze/background-launch policy, which Nordic does not address.

---

## Server reuse

**Reusable as-is (Option B):** the upload contract (`POST /v1/ingest-decoded`, `{device:{id},
streams:{…}}`, Bearer), the model already accepts all 8 streams, the pull-back/dashboard endpoints
(`/v1/streams`, `/v1/daily`, `/v1/sleep`, `/v1/workouts`, `/v1/backfill-workouts`), and idempotent
`(device_id, ts)` upserts — so an Android device with its **own** `device.id` coexists cleanly with
the iPhone's data. **Must change: nothing** (Option B). [CODE]

---

## Effort (corrected — recommended path = Option B)

| Component | Size | Notes |
|---|---|---|
| BLE scan/connect/discover + permissions + FGS scaffolding | M | Nordic reduces it |
| Bond trigger + bond-state + retry-after-bond | M | The risky bit; small code, real-device iteration |
| Connect handshake + offload + ack loop | M | Opcodes fully specified; needs command-queue discipline |
| Framing + CRC8/CRC32 reassembler (Kotlin) | S | ~1 day; CRC32 free from `java.util.zip.CRC32` |
| Schema loader + walker + type-47 V24 + event/metadata post-hooks | **S–M** | ~1 week realistic for **byte-parity** by someone new to the protocol; post-hooks are **hand-ported** (e.g. battery offsets 17/21/26), parity hazards: Int-before-Double scalar decode, integral-float-as-int JSON round-trip |
| Parity harness (reuse `frames.json`/`golden.json`/`historical_*`) | S | Fixtures are language-neutral; an **oracle to prove parity once written** (not pre-proof) |
| Local store + upload + sync watermark + timers | M | Mirror `Uploader.swift` |
| Reconnection / Doze / 133 hardening | M | Open-ended real-device tuning — where the schedule risk lives |

**Overall: several weeks to a couple of months** for a single experienced Android dev to a
*reliably* backgrounded collector. The protocol/decode is ~1 week and low-risk; **all** the schedule
risk and error-bar is in Android BLE lifecycle hardening + the two gates. ("A few focused weeks" is
the optimistic floor, not the expected value.) [INFERENCE]

---

## Testing story

- **Favorable:** you own a working 4.0 → fully end-to-end testable. The decoder validates **offline**
  against the reusable golden fixtures before any band is involved.
- **Need:** a physical **Android device** (emulators have no real BLE). Ideally span a few Android
  versions — bonding/auto-retry differs across 6/7 vs 8+ — so "fully testable" is true on *one*
  config, not the version matrix where the risk lives.
- **One-central wrinkle:** the 4.0 allows only one active connection but **retains multiple bonds**.
  To test on Android, **release the iPhone link first** (disconnect / kill the WHOOP app / move it
  out of range). You should **not** need to forget the iPhone bond — the band keeps both; hand-off is
  a reconnect, not a full re-pair (blue-LED pairing mode only needed if a bond is removed).

---

## Risks & unknowns (corrected)

1. **[HIGHEST — UNPROVEN, not high-confidence] Third-party Android bond.** Confirmed: the band bonds
   with the *official* Android app + iPhone; mechanism is Just-Works on a confirmed write. **Not
   confirmed:** that a custom `BluetoothGatt` client triggers it — no working Android client exists in
   the evidence (the one attempt was a sniffer stuck on the checksum), and sources disagree on whether
   Android auto-initiates pairing. **The go/no-go gate; verify empirically first.**
2. **[CONDITIONAL BLOCKER] Background/Doze.** The 15-min offload only runs while connected; Android
   12+ blocks FGS-start-from-background; Nordic doesn't solve Doze/process-death. A collector that
   silently stops overnight in a pocket is arguably a *functional* blocker for a 24/7 tracker, not a
   polish item — depends on accepting a permanently-foregrounded collector.
3. **Bonding edge cases / version variance**, **GATT-133 churn** — standard, handled by discipline +
   Nordic.
4. **Library choice:** native **Kotlin + Nordic Android-BLE-Library (+ble-ktx)** is the pragmatic pick
   (built-in queue, bonding, OEM workarounds). **Kable (KMP)** only if the long-term "phone-only /
   shared Swift+Kotlin" direction matters, at the cost of hand-handling more edge cases. **No native
   core exists to share via JNI** — the decode is reimplemented in Kotlin regardless.
5. **ToS/legal:** local BLE RE of a device you own, no cloud API. WHOOP officially supports an Android
   "broadcasting mode" (standard HR/R-R only); third-party custom-service access is unsanctioned RE —
   same posture as the existing iOS app.
6. **Don't trust community UUID maps** — some web sources use a shifted `61080000…`/wrong char roles;
   the code-authoritative map (`61080001` service, `61080002` command-write) is the one to use.

---

## Recommendation

**Build Option B (full Kotlin client) with the Nordic Android-BLE-Library — but front-load the one
gating unknown before investing.**

1. **Milestone 0 — PROVE THE BOND (do FIRST, ~1–2 days).** Throwaway app: scan service `61080001`,
   connect `TRANSPORT_LE`, discover the custom service, issue **one confirmed write of
   `GET_BATTERY_LEVEL`(26,`[0x00]`)** to `61080002`. **Success = `BOND_BONDED` + a cmd-notify response
   on `61080003`.** (Release the iPhone link first.) This resolves Gate #1 on your own band + Android
   phone. If it does **not** bond cleanly, that single finding changes the verdict — stop and reassess.
2. **Milestone 1 — parity (parallel, offline):** port framing + type-47 V24 to Kotlin; pass the
   reusable `frames.json`/`golden.json`/`historical_*` fixtures for byte-parity with Python.
3. **Milestone 2 — one full offload:** connect handshake + offload + ack loop → decode → `POST
   /v1/ingest-decoded` → rows visible in TimescaleDB.
4. **Milestone 3 — reliability:** foreground service, `autoConnect` reconnect, 133/Doze hardening,
   900s backfill + 30s upload timers; **soak test** (this is where Gate #2 is decided).

**Net:** the protocol is de-risked and the band is in hand, so the project's whole risk profile is two
empirical questions — *does it bond* (Milestone 0, ~2 days) and *does it survive the background*
(Milestone 3 soak). Answer the first cheaply before committing to the rest.
