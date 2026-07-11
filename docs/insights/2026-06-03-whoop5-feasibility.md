# Feasibility: adding WHOOP 5.0 support to OpenWhoop

**Date:** 2026-06-03. Question: how hard would it be to make OpenWhoop (our gen4 stack —
iOS Swift app + Python server) also read a WHOOP 5.0, using the `reference/goose` project
(gen5; Swift app + Rust core) as the reference?

Method: a multi-agent research pass (code analysis of both repos + web research), a synthesis,
and an adversarial review. The review caught a headline-changing error in the first draft and
several overstatements; **this doc is the corrected version.** Claims are tagged **[CODE]**
(confirmed in goose or OpenWhoop source / real captures), **[COMMUNITY]** (public RE / reviewer
claim), or **[INFERENCE]**.

---

## TL;DR

- **Implementing the gen5 protocol is Moderate and well-specified** — goose already reverse-
  engineered it and, critically, **validated it against real WHOOP 5.0 wire data** (7 owned
  Android-btsnoop captures of the official app, in `goose/Rust/core/fixtures/owned/`, valid CRCs,
  HR/motion/history all decode). The frame format, CRCs, command numbers, and history-sync flow
  are known. **[CODE]**
- **The one thing that genuinely cannot be answered without a physical 5.0** is whether a
  *third-party, unbonded* app (the way OpenWhoop talks to your 4.0) is allowed to connect and read,
  or whether the 5.0 requires BLE bonding / link encryption / an app-layer auth step. goose's
  captures are of the **official app's bonded session**, decoded after the fact — they do *not*
  prove goose's own connect path works on a real strap. **[INFERENCE / unconfirmed]**
- **Net:** you could build and offline-test ~90% of a gen5 port today with zero hardware, using
  goose as spec + goose's fixtures as golden vectors. The remaining ~10% (does the link open for
  us, plus physiological unit calibration) needs one capture/validation pass against a real device.
- **Difficulty: Moderate to implement / Moderate-to-Hard to verify-and-ship.** Biggest blocker:
  the unbonded-connection / auth question on real 5.0 hardware.

---

## Confirmed 4.0 vs 5.0 differences

| Layer | 4.0 (yours) | 5.0 | Confidence |
|---|---|---|---|
| GATT service UUID | `61080001-8d6d-82b8-614a-1c8cb0f8dcc6` | `fd4b0001-cce1-4033-93ce-002d5875f58a` | **[CODE]** goose scans both; confirmed against real captures |
| Characteristics | `…0002` write, `…0003/04/05` notify, `…0007` debug | Same 5-role layout on the `fd4b…` base — only the service prefix changes | **[CODE]** clean 1:1 remap |
| Frame header | 4 bytes: `0xAA`, len u16 LE, **CRC8** (poly 0x07); payload + CRC32 | 8 bytes: `0xAA 01`, len u16 LE, `00 01`, **CRC16/MODBUS** over header; payload padded to 4-byte multiple + CRC32 | **[CODE]** both directions, incl. real captures |
| Command opcodes | `commandType=35` frame; standard opcode table | **Unchanged** — same opcodes (get_data_range=34, send_historical=22, set_clock=10…), same `COMMAND=35` frame type | **[CODE]** |
| Historical sync | get_data_range → send_historical → consume → ack → stop; payload = explicit **zero byte** | Same flow; payload = **empty** (the one behavioral delta); range request optional/skippable | **[CODE]** goose `payload_expectation_for_generation`: Gen5→Empty, Gen4→ZeroByte |
| Biometric record | type-47 **V24** dense fixed offsets (hr@21, rr@23+2n, spo2@68/70, skin_temp@72, resp@80…) | **K-model**: K7/9/12/18/24 carry HR markers at K-specific offsets; K17 optical/PPG; K10/K21 IMU; a gen5-only `Gen5Spo2Percentage` field exists. **Structurally different**, not a version bump. | **[CODE]** HR=validated against real captures; RR/PPG/temp = candidate; SpO2/resp/quality = not yet decoded |
| Sensors / cadence | 5 LEDs, MAX86171 AFE, ~1 Hz passive | Same optical array; ~26 Hz capture; "set sampling frequency" command; discrete skin-temp stream; **ECG is MG-hardware-only** (separate FCC ID + PCB) | **[COMMUNITY]** (sensors); ECG-on-plain-5.0 claim is one reviewer and likely wrong |
| Pairing / auth | No app-layer auth; only gate is BLE bonding (the "encryption insufficient" macOS-vs-iPhone issue you hit) | goose calls **no** explicit bonding API + sends a fixed client-hello, BUT its own validation harness models an `authenticated` session step, and its `.withResponse` writes can trigger implicit iOS bonding. **Not settled.** 5.0 runs on an Ambiq secure-boot-capable SoC. | **[INFERENCE / unconfirmed]** — the make-or-break unknown |
| Advertising name | `WHOOP <serial>` (the `4C…` is a per-device serial, **not** a "4.0" marker) | Also begins `WHOOP`; exact string unconfirmed. goose filters by **service UUID**, not name | **[COMMUNITY]** |

**Correction folded in from review:** an earlier draft (and OpenWhoop's own notes) suggested gen5
uses a "PUFFIN" command class (37/38). goose's running code contradicts this — gen5 straps
(device types Goose/Maverick) use the standard `COMMAND=35`; *Puffin is a separate product line*
mapped to **no** WHOOP generation. So the command frame-type does **not** need to change for gen5 —
only the header/CRC layer does. **[CODE]**

---

## What goose already solved (and how reusable it is)

goose is **Swift + Rust**, so its Swift BLE layer is the same language as OpenWhoop's app — but it's
**reference-grade, not drop-in**: ~12 `GooseBLEClient+*.swift` files coupled to goose's own types,
its Rust FFI bridge, and its state bookkeeping. Plan to **adapt/reimplement** into OpenWhoop's
`BLEManager`, not copy files.

| goose asset | Value to us |
|---|---|
| Dual-gen BLE discovery (scan both service UUIDs, tag gen by `610800` prefix) | Highest-leverage — fills OpenWhoop's worst gap (it only scans the gen4 UUID). Adapt into our `BLEManager`. |
| gen5 char-role selection (`fd4b0002` write, etc.) | Direct reference for our `didDiscoverCharacteristicsFor`. |
| V5 frame builder + CRC16-MODBUS + deframer | Reference spec for the new header variant. |
| Historical-sync state machine + the gen5 **empty-payload** delta | The most valuable behavioral spec; reimplement in our Swift+Python. |
| K-model decode offsets (HR markers, K17 optical, K10/K21 IMU) | Reference for our schema JSON; HR paths now backed by real captures. |
| **`fixtures/owned/` — 7 real 5.0 captures** + synthetic fixtures (UUID detection, history plan/markers, K18 golden hex) | **The crown jewel: golden test vectors from real 5.0 traffic.** Lets us validate a decoder with no hardware. |

**Do not take a Rust FFI dependency** — adding Rust to our Swift+Python stack costs more than
reimplementing the ~3 decode deltas from goose's documented offsets.

---

## What we could do today with NO hardware

All structural work is offline-testable against goose's fixtures:
1. Refactor OpenWhoop's transport into a gen-agnostic `StrapProfile` (service/char UUIDs, opcode
   map, frame variant, handshake, decode schema). OpenWhoop's `BLEManager` hardcodes gen4 across
   ~35 sites with no seam — this refactor is the single most valuable move and pays off for any
   future generation.
2. Implement + unit-test the gen5 frame builder/deframer (8-byte header, CRC16-MODBUS, CRC32) and
   round-trip goose's owned K10/K21/K24 hex through it, asserting Swift↔Python byte-parity (extend
   our existing 924-frame parity harness).
3. Build the gen5 handshake + history-sync state machine and test it against goose's command-trace
   fixtures.
4. Decode the gen5 K-model HR/motion paths against the real owned captures (HR is verified there).

## What ABSOLUTELY needs a physical 5.0

- **Whether an unbonded third-party app can connect/read at all** (bonding / link encryption /
  app-layer auth on the custom service). This is unfixable in software and is the make-or-break.
- True timestamp/counter semantics and **physiological unit calibration** (skin-temp/RR/SpO2
  scaling) — goose marks these unresolved even with its captures.
- Whether the fixed client-hello is accepted by a live strap; firmware-version variation.
- Anything involving **writes/commands** beyond read-only history.

**Highest-information single action:** one more Android HCI/btsnoop capture of the official app ↔ a
real 5.0 — but note goose *already has one*, which is why the decode layer is de-risked. A new
capture is mainly needed to study the **connect/auth handshake** (bonding, hello acceptance), which
goose's payload-only fixtures don't fully expose.

---

## Risks & unknowns

- **Pairing/auth/link-encryption (highest).** Unconfirmed for 5.0; goose's "no bonding" may be
  masking iOS auto-bonding. If 5.0 enforces LE Secure Connections on the custom service, our
  macOS/Python tooling hits the same wall as 4.0 and the app likely needs an explicit bond write.
- **DRM / firmware lockdown.** No confirmed app-layer DRM, but the Ambiq SoC ships stock secure
  boot + signed/encrypted OTA. Reads may stay open; writes unproven; firmware extraction (open on
  4.0) likely closed on 5.0.
- **ToS / legal.** WHOOP's ToU prohibits reverse-engineering / security bypass / non-Service device
  use; the API ToU prohibits algorithm extraction. **DMCA §1201 exposure is *higher* for 5.0** than
  the open 4.0 *if* technical protection measures are actually present. The device is
  subscription-tethered (account action can brick usefulness). goose's stance: RE prior-art
  reference, ships no binaries, copies no code — a sane model to mirror.
- **Byte-parity tax.** Every frame-layer/decode change must land twice (Swift + Python, across 3
  schema copies) and stay provably identical — a real multiplier on each task, not a backdrop.
- **Firmware OTA breakage.** An undocumented link can be changed by any WHOOP OTA. goose is
  self-described alpha.

---

## Recommendation

**Do the refactor now; defer gen5 go-live until a real 5.0 can be captured/validated. Use goose as
spec + fixtures; no Rust FFI.**

1. **Abstract a gen-agnostic `StrapProfile` transport in OpenWhoop now** — 100% testable without
   hardware, fixes the documented `BLEManager` bottleneck, pays off for any generation.
2. **Adapt goose's Swift transport deltas** (dual-UUID scan, `fd4b0002` char selection, 8-byte/
   CRC16 frame build/deframe, client-hello) into it. Reimplement the history-sync empty-payload
   delta + K-model decode from goose's offsets.
3. **Wire goose's fixtures (especially `fixtures/owned/`) in as OpenWhoop tests** and extend the
   Swift↔Python parity harness to gen5. Result: a structurally-validated gen5 stack, zero hardware.
4. **Before real-device go-live**, get an Android HCI capture of the official app ↔ a real 5.0 to
   resolve the connect/auth question; treat "unbonded read works" as unproven until then.
5. **Buy vs borrow:** borrow / short-term-buy a 5.0 for one validation pass; don't commit to owning
   one until step 4 confirms the link is open for third parties. If it reveals enforced encryption
   or an app-layer gate, **stop and reassess** — that's where Hard becomes possibly-infeasible, with
   the added DMCA exposure the open 4.0 never carried.
6. **Legal posture:** personal interoperability only, no redistributed binaries, no algorithm
   extraction; confirm before anything goes public.

**The protocol is largely de-risked on paper *and* against real 5.0 wire data. What code can't buy
is the answer to "does a real 5.0 let an unbonded third-party app read it" — so build and green
everything except that, offline, before touching a physical strap.**
