# Proposed analysis fixes + evaluation plan

**Date:** 2026-06-02. Companion to the audit (`docs/2026-06-02-analysis-audit.md`) and the
deep literature addendum (`docs/2026-06-02-analysis-audit-literature-addendum.md`).

**Status: PROPOSALS ONLY — nothing below is applied.** The plan is to **A/B each fix
against our own accumulating data** and compare/contrast results once there's enough of it
(~1 week of continuous wear). **Reconvene ~2026-06-09.**

This works because of the pipeline's separation of concerns: the raw decoded streams are
immutable in TimescaleDB, and `compute_day()` / `POST /v1/compute-daily` / `POST
/v1/backfill-workouts` re-derive metrics idempotently. So we can recompute the SAME stored
data under "before" and "after" code and diff the outputs directly — no re-collection needed.
(The one exception: respiration is signal-limited at 1 Hz and cannot be fixed by re-analysis.)

---

## Why (one-line per metric, from the audit)
- **Sleep:** stage split (~88% light) implausible; weak without EEG (~72% ceiling, Walch 2019). Needs nights + respiration fix.
- **HRV:** formula correct, but PPG underestimates RMSSD ~3–4 ms vs ECG and a single artifact can inflate RMSSD +413% (Sensors 2022) — no artifact gate today.
- **Recovery+baselines:** baseline machinery is best-practice; today's 84 is a cold-start fallback (needs ≥4 nights); composite score is unvalidated industry-wide.
- **Strain:** standard method; 0–21 scaling constant un-fitted; HRmax thin at 1 day.
- **Exercise:** strongest; thresholds single-user-tuned.
- **Calories:** blocked on missing anthropometry; Harris-Benedict ~32 pp less accurate than Mifflin-St Jeor.
- **Signals:** SpO₂ uncalibrated (86.6% not real; skin-tone bias); respiration physically inadequate at 1 Hz (needs ≥100 Hz); skin-temp deviation OK as trend only.

---

## Proposed changes (verbatim diffs)

### Change 1 — Calories: Harris-Benedict → Mifflin-St Jeor BMR (`analysis/calories.py`)
Mifflin: `10·kg + 6.25·cm − 5·age + s` (s = +5 male / −161 female). Height coeff ×100 (code applies height in metres). Function structure unchanged.

```diff
     "male": {
-        # Harris–Benedict (revised, SI): 88.362 + 13.397·kg + 4.799·cm − 5.677·age
-        "resting_alpha":   88.362,
-        "resting_weight":  13.397,
-        "resting_height":  479.9,
-        "resting_age":     5.677,
+        # Mifflin-St Jeor (1990): 10·kg + 6.25·cm − 5·age + 5
+        "resting_alpha":     5.0,
+        "resting_weight":   10.0,
+        "resting_height":  625.0,
+        "resting_age":       5.0,
     },
     "female": {
-        "resting_alpha":   447.593,
-        "resting_weight":    9.247,
-        "resting_height":  309.8,
-        "resting_age":       4.33,
+        # Mifflin-St Jeor: 10·kg + 6.25·cm − 5·age − 161
+        "resting_alpha":  -161.0,
+        "resting_weight":   10.0,
+        "resting_height":  625.0,
+        "resting_age":       5.0,
     },
     "nonbinary": {   # mean → alpha (5 + −161)/2 = −78
-        "resting_alpha":   267.9775,
-        "resting_weight":   11.322,
-        "resting_height":  394.85,
-        "resting_age":       5.0035,
+        "resting_alpha":   -78.0,
+        "resting_weight":   10.0,
+        "resting_height":  625.0,
+        "resting_age":       5.0,
     },
```
Prerequisite: enter real weight/height/age/sex (profile) — otherwise both versions use defaults (70 kg/170 cm/30 yr) and the comparison is meaningless.

### Change 2 — HRV: artifact-density gate + surface `artifact_rate` (`analysis/hrv.py`)
```diff
+#: Reject RMSSD when more than this fraction of beats were artifacts. Literature
+#: (Sensors 2022) finds RMSSD unreliable above ~0.9%; start at 5% and tune down
+#: against the observed artifact_rate distribution once multi-night data exists.
+MAX_ARTIFACT_RATE: float = 0.05
```
In `nightly_hrv`, just before the return:
```diff
+    artifact_rate = (n_art / n_beats) if n_beats else float("nan")
+    if n_beats and artifact_rate > MAX_ARTIFACT_RATE:
+        rmssd_chosen = float("nan")   # too many artifacts — RMSSD not trustworthy
     return {
         "rmssd": rmssd_chosen,
         ...
         "n_artifacts": n_art,
+        "artifact_rate": artifact_rate,
         ...
     }
```

### Change 3 — Respiration: don't emit a rate from noise (`analysis/units.py`, `_resp_rate_welch`)
```diff
-    peak_freq = float(freqs[mask][np.argmax(psd[mask])])
-    return peak_freq * 60.0  # Hz → BrPM
+    in_band = psd[mask]
+    peak_idx = int(np.argmax(in_band))
+    peak_freq = float(freqs[mask][peak_idx])
+    # A real breathing peak should clearly dominate the in-band spectrum; if not,
+    # the "rate" is low-frequency drift/motion (source of spurious ~7 BrPM). Refuse it.
+    med = float(np.median(in_band))
+    if med <= 0 or float(in_band[peak_idx]) < 2.0 * med:
+        return None
+    return peak_freq * 60.0  # Hz → BrPM
```
NOTE: this only suppresses junk; the real fix for respiration is ≥100 Hz sampling (collection change, deferred).

### Change 4 — SpO₂ honesty (output layer; needs a `daily.py` `_nightly_signals` diff)
Presentation, not math: either return `None` for `spo2_pct` until `fit_spo2()` has run, or add a `signals_calibrated: false` flag so the app stops showing 86.6% as a clinical %. Exact diff TBD against `daily.py` (not yet pulled).

### Non-code (parallel, no waiting)
- Enter weight/height/age/sex (profile) → unblocks calories + a real Tanaka HRmax guard.
- Log a few WHOOP-app reference values → run `fit_spo2()` / `fit_skin_temp()` / `fit_strain_denominator()`.

---

## Evaluation methodology (A/B against our own data)

General loop per fix: branch the change → `backfill-workouts` / `compute-daily` to recompute the
accumulated history under both "before" and "after" → diff the per-day outputs → judge.

| Fix | What to compare | Success criterion | Data needed |
|---|---|---|---|
| **1 Calories (Mifflin)** | Recompute kcal both ways over all days; if WHOOP screenshots logged, compare to those | Resting-driven kcal drops ~5–10% and lands closer to WHOOP app + Mifflin's published accuracy | Anthropometry entered; ideally a few WHOOP calorie refs |
| **2 HRV gate** | Distribution of `artifact_rate` across nights; which nights get NaN'd; do obviously-inflated RMSSD spikes disappear | Removes implausible RMSSD outliers WITHOUT nuking most nights; then tune `MAX_ARTIFACT_RATE` toward the literature's ~0.9% if the data supports it | ~1–2 weeks of nights to see the artifact_rate distribution |
| **3 Respiration gate** | How often it now returns `None` vs a value; are the spurious ~7/min cases gone | Stops emitting implausible rates; honest "unavailable at 1 Hz" rather than a fake number | A few nights |
| **4 SpO₂ labeling** | App no longer presents 86.6% as a clinical %; vs WHOOP SpO₂ after `fit_spo2()` | SpO₂ shown as uncalibrated/withheld until fitted | WHOOP SpO₂ refs for the fit |

Cross-cutting: most accuracy questions ALSO need the audit's data-collection gates
(`docs/2026-06-02-analysis-audit.md` §3) — recovery real at ~4 nights, baselines at ~14–30,
HRmax at ~90 days.

---

## Reconvene checklist (~2026-06-09, after ~1 week of wear)
1. Confirm data volume (nights of continuous wear; is recovery seeded? baselines exiting "calibrating"?).
2. Apply Changes 1–3 on a branch; recompute history both ways; diff outputs (the A/B above).
3. If WHOOP reference values were logged, run the `fit_*()` calibrations and re-evaluate SpO₂/skin-temp/strain.
4. Decide per fix: keep / tune thresholds / revert. Tune `MAX_ARTIFACT_RATE` against the observed artifact_rate distribution.
5. Re-audit sleep-stage split (did it normalize past ~88% light once percentile bands stabilized?).
6. If keeping fixes: commit on `local/dormant-strap-recovery` (commit as the user, no AI attribution).

---

## Bug fix (implemented 2026-06-03) — recovery cold-start gate missed the no-baseline case

**Not part of the 4-fix A/B set above; this is a correctness bug, fixed + tested (red→green).**

**Symptom:** recovery showed ~84% on the first night (2026-06-02) but `null` from the second
night on (06-03+). Looked like recovery "broke" / stopped updating.

**Root cause:** `recovery.recovery_score`'s cold-start gate only returned `None` for a
*non-usable `BaselineState`*. On the very first night `daily._build_baselines` finds zero prior
`daily_metrics` rows and returns `{"hrv": None, ...}`; with the HRV/RHR baseline terms dropped
(absent) but `sleep_perf` supplied by `daily.compute_day`, the composite fell through to a
**sleep-efficiency-ONLY** logistic. The 84.27 on 06-02 was literally just ~95% sleep efficiency
squashed through the curve — not a baseline-grounded recovery. From night 2 the baseline became a
real-but-unusable `BaselineState` (1 < `MIN_NIGHTS_SEED`=4), so the gate correctly fired → `null`.
So the first number was the wrong one; the nulls are correct.

**Fix (`analysis/recovery.py`):** the gate now also returns `None` when there is no usable HRV
baseline at all (None / absent key), since HRV is the dominant driver (W=0.60). Legacy plain-float
/ `(mean, spread)` baselines still score (caller-supplied → trusted), so no existing behavior
regresses.

**Tests (`tests/test_recovery.py`, `TestRecoveryNoHrvBaselineGate`):** 4 new cases (empty / None /
`{"hrv": None}` / HRV-absent-but-RHR-present, each with `sleep_perf` set) now assert `None`; a
guard asserts the usable-baseline case still scores. Red→green confirmed; recovery + baselines
suites = 98 passed.

**Effect:** recovery for normal nights still appears once ≥4 baseline nights accumulate
(~2026-06-06). The only behavior change is the first-night case: it now returns `null` (honest)
instead of a sleep-only score. **Action:** recompute 2026-06-02 to clear its stale 84.27 once the
fix is deployed.

---

## Finding (2026-06-07) — HRV volatility is NOT artifacts; reprioritize fix #2

Ran the pipeline's own `clean_rr` (range filter + Kubios) over each night's sleep-window R-R for
06-02..06-07. **Artifact rates are 0.17–0.38% on every night** — well under the literature ~0.9%
reliability bar and the proposed 5% gate. The R-R is clean; Kubios only trims RMSSD a uniform
~5–10ms. So the big reported-HRV swings (42.8 on 06-06 up to 87.5 on 06-07) are **real signal**,
not artifacts.

The swing is driven by the **last-SWS HRV window selection** + the **immature baseline**, not bad
beats. Whole-night cleaned RMSSD is far steadier (44–64) than the reported last-SWS values (43–88):
06-07 reported 87.5 but whole-night was 63.7; 06-03 reported 47.1 but whole-night 58.9; 06-06's low
(42.8) matches whole-night (44.0), so that low is genuine (heavy-load day).

**Reprioritization for the review:** Fix #2 (artifact-density gate) is now **low value** — the data
is too clean for it to change anything (keep as cheap hygiene, but it does NOT fix recovery
volatility, contrary to the earlier assumption). The real levers for steadier recovery: (a) baseline
maturity (time, ~14 nights), and (b) a possible HRV-window change (whole-night is steadier but
diverges from WHOOP's last-SWS method — a design tradeoff to weigh, not an obvious win).
