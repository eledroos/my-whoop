This fills in the gaps for the empty audit areas. I now have verified, concrete detail for all six audit areas. Key findings:

- **HRV** (`hrv.py`): Full Kubios/Lipponen-Tarvainen (2019) cleaning pipeline, range filter [300, 2000] ms, Task Force RMSSD in float64. Well-built.
- **Recovery** (`recovery.py`): HRV-dominant z-score model (W=0.60 HRV / 0.20 RHR / 0.05 resp), needs `MIN_NIGHTS_SEED=4` valid nights or returns `None`. So today's 84.3 is a cold-start substitute, not a real baseline-normalized score.
- **Baselines** (`baselines.py`): EWMA (14-day half-life) + windowed MAD over trailing 30 nights, Winsorized cold-start with "calibrating" status.
- **Calories** (`calories.py`): Keytel (2005) HR-based active EE + revised Harris-Benedict BMR — both need user anthropometry (weight/height/age/sex).
- **Exercise** (`exercise.py`): Sustained ≥5-min Karvonen %HRR window, ≥60% HRR intensity gate. Independent design on published primitives.

I have everything needed. Writing the report now.

---

# WHOOP-de-doo Analysis Server — Final Audit Report

## 1. HEADLINE

**The dominant fact is data starvation, not code quality.** As of 2026-06-02 the server holds roughly **one day** of real data (one night + one day) after a ~21-month dormancy. Almost every metric depends on trailing windows that are essentially empty: recovery needs **≥4 nights** to seed (`recovery.py` `MIN_NIGHTS_SEED=4`), baselines use a **30-day** EWMA + MAD window (`baselines.py`), and HRmax uses a **90-day** percentile (`strain.py`). So today's numbers are best read as *cold-start placeholders*, not validated outputs. **No metric's accuracy can be externally validated yet** — there is no ground truth and no baseline to normalize against.

The code itself is, on the whole, **honest and competently built**: it cites real literature (Walch 2019, Cole-Kripke 1992, Karvonen 1957, Edwards 1993, Banister 1991, Tanaka 2001, Keytel 2005, Harris-Benedict, Task Force 1996 / Lipponen-Tarvainen 2019), wraps risky steps in try/except, and explicitly flags its own un-calibrated constants in docstrings (`units.py` header: "ALL OUTPUTS ARE APPROXIMATE / UN-CALIBRATED until calibration-fitting routines [run]").

**Observed outputs that are clearly off (independent of data volume):**
- **resp_rate_bpm = 7.0** — about half a normal adult rate (12-20 brpm). Root cause is **1 Hz sampling + no calibration**, not an algorithm bug (`sleep_features.py`). The peak-detection method is sound but starved of signal.
- **spo2_pct = 86.6%** — implausibly low for sleep (normal 94-99%). This is an **un-calibrated ratio-of-ratios ADC map** (`units.py`: `SpO2 = a − b·R`, clamped [70,100]), reported in "%" units it has not earned.
- **Sleep stages ~88% light / 17.5 min deep** — atypical architecture (normal ~50-60% light, ~15-20% deep, 20-25% REM). Most likely a **percentile-calibration artifact** of a single night (too few epochs to compute stable per-night bands) compounded by respiration NaNs demoting REM→light.
- **skin_temp_dev_c = null** — correct behavior: deviation needs a 30-day baseline that does not exist yet.

The other observed numbers (recovery 84.3, strain ~13.2, RHR 53, HRV 75/69 ms) are *plausible* but **unvalidated** and, in recovery's case, **not yet a real score** (it's the cold-start fallback path).

---

## 2. PER-METRIC VERDICT TABLE

| Metric | What it computes | Verdict | Can we assess it yet? | #1 improvement |
|---|---|---|---|---|
| **Sleep detection + 4-class staging** | TST, efficiency, light/deep/REM min, SOL, REM latency, WASO, disturbances, RHR, nightly HRV | **weak-or-approximate** | **No** (needs PSG GT + multi-night percentile calibration; literature ceiling ~72% for EEG-free 4-class, Walch 2019) | Fix respiration signal quality (drives REM→light bias); pool percentile bands across 3-7 nights |
| **HRV (RMSSD/SDNN + cleaning)** | Range-filtered + Kubios/Lipponen-Tarvainen 2019 cleaned RMSSD/SDNN, float64 Task Force formula | **plausible-unvalidated** (strongest module) | **Partially** — formula/neurokit2 parity verifiable now; trend/baseline No | Confirm per-epoch (range-only) vs full-session (Kubios) HRV correlate once data exists |
| **Recovery + baselines** | HRV-dominant z-score (W=0.60 HRV / 0.20 RHR / 0.05 resp) vs personal baseline; EWMA(14d) + MAD(30d) | **plausible-unvalidated** — *but today's 84.3 is the cold-start fallback, not a seeded score* | **No** — `MIN_NIGHTS_SEED=4` not met; baseline status = "calibrating" | Surface calibration status ("calibrating, N/4 nights") in output so 84.3 isn't mistaken for real |
| **Strain (0-21) + HRmax** | Karvonen %HRR → Edwards/Banister TRIMP → 21·ln(TRIMP+1)/ln(D); HRmax = p99.5 of 90d HR | **plausible-unvalidated** | **No** — `STRAIN_DENOMINATOR=7201` is un-fitted; HRmax p99.5 thin-tailed at 1 day | Log WHOOP reference strain for 3-4 days, run `fit_strain_denominator()` |
| **Exercise / activity detection** | Sustained ≥5-min (`MIN_EXERCISE_MIN`) windows ≥60% HRR (`MIN_INTENSITY_Z2PLUS=0.50`); zone %, avg %HRR | **plausible-unvalidated** | **Partially** — 2 bouts detected today are spot-checkable vs memory; accuracy No | Validate bout boundaries against a few logged real workouts |
| **Calories** | Keytel 2005 HR-based active EE + revised Harris-Benedict BMR | **plausible-unvalidated, BLOCKED on inputs** | **No** — requires weight/height/age/sex; not in codebase | Add user anthropometry inputs; without them calories cannot be computed correctly |
| **Signals: SpO2 / skin-temp / resp** | Un-calibrated ADC→%, ADC→°C, 1 Hz resp peak rate | **weak-or-approximate (uncalibrated)** | **No** — all three need calibration fits + multi-night baselines | Stop reporting SpO2 as "%" until calibrated; gate resp to NaN when implausible |

*(HRV, recovery-baselines, exercise, calories, and signals arrived as empty audit stubs; verdicts above are grounded in direct reads of `hrv.py`, `recovery.py`, `baselines.py`, `exercise.py`, `calories.py`, `units.py`, plus the strain/sleep audits and the observed outputs. Flagged accordingly.)*

---

## 3. DATA-SUFFICIENCY REALITY CHECK

### Per-metric: data to (a) PRODUCE vs (b) VALIDATE

| Metric | (a) Produce an output | (b) Validate accuracy |
|---|---|---|
| Sleep/wake detection | 1 night (have it) | Self-report cross-check now (gross errors); PSG/certified actigraphy for true accuracy (not available) |
| Sleep staging (4-class) | 1 night | PSG ground truth — *fundamentally unavailable here*; literature ceiling ~72% (Walch 2019). Best achievable is internal consistency + multi-night plausibility |
| HRV (RMSSD) | 1 night | Formula verifiable now (neurokit2 parity); trend needs ~2-4 weeks |
| Recovery score | **≥4 valid nights** to seed; <4 returns None / cold-start | ~30 nights for a trustworthy baseline; WHOOP reference for absolute accuracy |
| Baselines (EWMA/MAD) | "calibrating" until ~14 nights; stable ~30 nights | 30+ nights; no external GT needed for internal stability |
| Strain magnitude | 1 day (>600 samples) — output is produced | 3-4 days of paired WHOOP strain → `fit_strain_denominator()` |
| HRmax (p99.5) | 1 day (thin tail, artifact-prone) | ~90 days for robust p99.5; lab graded-exercise test for true HRmax |
| Exercise detection | 1 day (2 bouts found) | A few logged real workouts for boundary/zone accuracy; 1-2 weeks for consistency |
| Calories | **Blocked** until anthropometry added | WHOOP reference calories once inputs exist |
| SpO2 | 1 night (but uncalibrated → unreliable) | `fit_spo2()` needs WHOOP/transcutaneous GT; 7+ nights for baseline |
| Skin-temp deviation | **30-night baseline** (currently null) | `fit_skin_temp()` + 14-30 nights |
| Respiration rate | 1 night (but 7.0 brpm is signal-limited) | Manual breath counts or certified device; ideally ≥10 Hz sampling |

### CONCRETE DATA-COLLECTION PLAN (normal continuous wear, starting 2026-06-02)

This is the order things "unlock." Assumes nightly wear with good strap contact.

- **Night 1 (done):** Sleep/wake, raw HRV, exercise bouts, strain *magnitude*, signals — all **produced** but none validated. Recovery is cold-start. Use this night to spot-check gross sleep duration vs how long you actually slept.
- **By ~4 nights (≈2026-06-05):** Recovery seeding threshold met (`MIN_NIGHTS_SEED=4`) — recovery starts producing a *real* baseline-normalized score instead of the fallback. **Re-check the sleep stage split here**: if classifier is healthy, deep should climb toward ~15-20% as percentile bands stabilize. If it's still ~88% light, that's a real signal-quality/threshold problem, not just small-sample noise.
- **By ~7 nights (≈2026-06-08):** Enough nights to pool sleep-staging percentile bands across nights and to sanity-check SpO2-burden / arousal-style metrics. Audit deep-sleep distribution across the night (validates/relaxes `DEEP_FIRST_FRACTION=1/3`).
- **By ~14 nights (≈2026-06-15):** Baselines exit "calibrating"; EWMA(14d half-life) becomes meaningful. Sleep-debt and HRV-trend metrics become interpretable. Recovery score is now reasonably trustworthy directionally.
- **By ~30 nights (≈2026-07-01):** Full baseline window populated — recovery, RHR-deviation, skin-temp-deviation (illness flag), and resp-deviation all become trustworthy *relative* signals. `skin_temp_dev_c` stops being null.
- **By ~90 days (≈2026-08-31):** HRmax p99.5 over ~7.8M samples becomes artifact-robust; strain absolute magnitude is stable (assuming denominator calibrated earlier).

**Calibration tasks that do NOT wait for data accumulation** (do these in parallel, any day):
- Log 3-4 days of WHOOP app strain screenshots → `fit_strain_denominator()`.
- Capture WHOOP SpO2 readings → `fit_spo2()`. WHOOP skin-temp → `fit_skin_temp()`.
- Enter weight/height/age/sex → unblocks calories *and* the Tanaka HRmax fallback (currently age is unknown so Tanaka rarely acts as a guard).

---

## 4. NEW METRICS (prioritized: feasible-now first)

### Tier A — Feasible now (low difficulty, reuses existing outputs)

1. **Post-Exercise Heart-Rate Recovery (HRR)** — *difficulty: low.* Slope of HR over the first 60-120 s after a detected bout (bpm/min). **Why:** strong independent mortality/fitness predictor (GE Healthcare; Cole et al. 2000); tracked by Garmin/Polar. **How:** take `detect_exercises()` end times, linear-fit HR(t) over t∈[0,120s], report |slope|·60 + R². **Data:** computable today (2 bouts exist); 1-2 weeks for trend. *Best immediate ROI — pure reuse of the exercise module.*

2. **Sleep Debt / Sleep-Need Deficit** — *difficulty: low.* Rolling 7/14-day deficit vs personal need. **Why:** novel vs WHOOP/Oura; cumulative debt drives cognitive/immune decline (Van Dongen 2003). **How:** need ≈ median(last-30 nightly TST) capped [6,9]h; deficit = max(0, need − TST); flag debt_7d >5h. **Data:** produced day 1 (today's 6.56h is below 7.5h), but need-baseline wants ~14-30 nights.

3. **Resting Metabolic Rate proxy** — *difficulty: low, but BLOCKED on anthropometry.* Mifflin-St Jeor / Harris-Benedict adjusted by RHR deviation. **Why:** complements calories. **How:** same coefficient infrastructure already in `calories.py`. **Data:** needs weight/height/age/sex (same blocker as calories) + 7-14 nights of RHR.

### Tier B — Feasible after baselines exist (medium difficulty)

4. **Sympathovagal Balance (LF/HF)** — *medium.* Welch PSD ratio of LF[0.04-0.15Hz]/HF[0.15-0.4Hz] on cleaned RR (Task Force 1996). **Why:** frequency-domain complement to RMSSD; stress/overtraining signal. **How:** reuse `clean_rr()`, interpolate to 4 Hz, `scipy.signal.welch`. **Data:** computable now per night; needs 4-7 nights for baseline. *Note Laborde 2017 interpretation caveats — LF/HF is not cleanly "sympathetic."*

5. **Cardiac Ectopic Burden (PVC/PAC proxy)** — *medium.* Count RR intervals >2σ from nightly mean. **Why:** rhythm-regularity dimension RHR/HRV miss. **How:** filter RR [300,2000]ms (already in `hrv.py`), flag outliers, normalize per hour. **Data:** 1 clean night gives a reading; 7+ nights for personal baseline (benign ectopy varies widely).

6. **Cortical Arousal Index** — *medium.* Fuse gravity L2-delta motion spikes + RR-variability spikes → arousals/hour. **Why:** fragmentation marker; cross-checks the existing `disturbances` field (9 tonight ≈ ~18/hr if accurate). **How:** reuse the gravity stillness spine from `sleep.py`. **Data:** 3-5 nights to calibrate motion threshold.

7. **Illness/Fever Detection (skin-temp deviation + pattern)** — *medium.* Flag sustained skin-temp elevation >0.5°C vs baseline. **Why:** wearables detect infection 1-2 days pre-symptom (Stanford 2018). **How:** extend the existing `skin_temp_dev_c` path. **Data:** **blocked** until `fit_skin_temp()` runs AND 14-30 night baseline exists (currently null).

8. **Nocturnal SpO2 Burden (AUC below threshold)** — *medium.* %-minutes below 90/88/85%. **Why:** cumulative hypoxemia is more clinical than single dips. **How:** integrate `spo2_percent_window` over sleep. **Data:** **blocked** until SpO2 is calibrated — today's 86.6% would falsely flag massive burden.

9. **VO2max / Aerobic Capacity** — *medium.* `15.3·(HRmax/RHR)` (Uth) or regression. **Why:** strongest longevity predictor; Garmin MAPE ~6.85%. **How:** uses HRmax (`strain.py`) + nightly RHR. **Data:** needs robust HRmax (~90 days) + ≥3 peak workouts; low confidence before that.

### Tier C — Hard / blocked (defer)

10. **Sleep Apnea Screening (AHI proxy)** — *high.* Needs calibrated SpO2 + reliable respiration — **both currently broken** (86.6%, 7.0 brpm). Defer until signals fixed; ~7 nights after.
11. **Pulse Wave Velocity / arterial stiffness** — *high.* Needs PPG fiducials from red/IR; current AC signal is weak (red~587/ir~585). Likely needs >1 Hz raw PPG. Defer.
12. **Lactate Threshold proxy** — *high.* Needs ramped/structured workouts ≥20 min; today's bouts (8/16 min, flat) are too short. Defer until structured-workout data exists.

---

## 5. PRIORITIZED RECOMMENDATIONS

Ordered to fit the plan: **improve analysis on accumulating data first, defer architecture.**

### Quick wins — fix clearly-broken / uncalibrated things NOW (days, no new data)

1. **Stop reporting SpO2 as a literal "%".** 86.6% will be read as clinical hypoxemia. Until `fit_spo2()` is calibrated against WHOOP ground truth, label it `spo2_raw_index (uncalibrated)` or suppress it. *(`units.py` already warns it's approximate — make the output honest too.)*
2. **Gate respiration to NaN when implausible.** Add: if peak count <5 or detrended-resp std too low, return NaN instead of 7.0 brpm; log a warning when outside [6,30]. Add a low-pass (~2 Hz) pre-filter. *(`sleep_features.py` resp block.)*
3. **Surface calibration/seeding status in every output.** Recovery should emit `status: "calibrating (1/4 nights)"` so 84.3 isn't mistaken for a seeded score. Baselines already compute a "calibrating" status — propagate it. Add a strain `calibration_status: uncalibrated` field tied to `STRAIN_DENOMINATOR`.
4. **Run the calibration fits that don't need accumulation:** log 3-4 days of WHOOP app strain → `fit_strain_denominator()`; capture WHOOP SpO2/skin-temp → `fit_spo2()`/`fit_skin_temp()`. This is the single biggest accuracy lever available immediately.
5. **Add user anthropometry (weight/height/age/sex).** Unblocks calories entirely and gives Tanaka HRmax a real lower-bound guard (currently age unknown). Pure input, no algorithm work.
6. **Add the cheap unit-test safety net** the sleep audit calls for: stage-sum = TST (±1s), percentile gates ordered (HR_LOW_PCT ≤ HR_HIGH_PCT), onset/final-wake indices in range, RMSSD/Cole-Kripke/AASM match references. These catch regressions while data accumulates.

### Needs more data — schedule the re-checks, don't touch code yet

7. **At ~4 nights:** re-evaluate the sleep stage split. If deep is still ~88% light after percentile bands stabilize, *then* it's a real threshold/signal problem (audit `STAGE_STILL_MOVE_FRAC=0.10`, respiration NaNs); if it normalizes, it was small-sample noise.
8. **At ~7 nights:** pool sleep-staging percentile bands across nights (the audit's #1 staging fix) and audit deep-sleep clock distribution.
9. **At ~30 nights:** confirm recovery/baseline behavior, expect `skin_temp_dev_c` to populate, enable illness-flag thresholds.
10. **At ~90 days:** confirm HRmax p99.5 stability; finalize strain magnitude.

### Real work — defer until data justifies it (and only the high-value ones)

11. **Build HRR (Tier A #1) now** — it's low-effort, reuses the exercise module, and is computable from today's 2 bouts. Best new-metric ROI.
12. **Add Sleep Debt (Tier A #2)** — low effort, reuses daily sleep summaries; meaningful by ~14 nights.
13. **Defer all high-difficulty proposals** (apnea AHI, PWV, lactate threshold) — they depend on signals that are currently broken (SpO2, resp) or on data that doesn't exist (structured ramped workouts, ≥10 Hz PPG). Revisit after quick-wins #1-#2 fix the signals.
14. **Bigger architectural item, lowest priority:** higher-rate BLE sampling (≥10 Hz resp/PPG) would structurally fix respiration and unlock PWV/apnea — but per the user's plan, defer this until the analysis-on-real-data work is exhausted.

**Bottom line:** the code is honest and largely correct against its cited literature; the limiting factor is ~1 day of data plus three concretely-fixable issues (uncalibrated SpO2, signal-starved respiration, single-night staging artifact). Do the calibration fits + honesty-labeling now, let the trailing windows fill, and re-audit accuracy at the 4 / 7 / 30 / 90-night gates.

**Files referenced:** `/Users/nasser/_dev/whoop-de-doo/my-whoop/server/ingest/app/analysis/{sleep.py, sleep_features.py, hrv.py, recovery.py, baselines.py, strain.py, exercise.py, calories.py, units.py, daily.py}` and `/Users/nasser/_dev/whoop-de-doo/my-whoop/server/ingest/app/analysis/validation/{plausibility.py, stats.py, report.py, targets.py}`.


---

## Appendix — New-metric proposals (detail)


### Sympathovagal Balance (LF/HF Ratio)  _(difficulty: medium)_
- **Signals:** RR intervals (heart rate variability time series)
- **What:** Frequency-domain HRV metric measuring relative autonomic nervous system balance by computing the power ratio of low-frequency (0.04–0.15 Hz) to high-frequency (0.15–0.4 Hz) components during sleep. LF is traditionally mixed sympathetic-parasympathetic; HF is predominantly parasympathetic. Higher LF/HF suggests sympathetic dominance (stress/arousal); lower indicates parasympathetic dominance (recovery).
- **Why:** Complements RMSSD (time-domain HRV) with frequency-domain autonomic insight. Oura Ring and academic literature emphasize sympathovagal balance for readiness/recovery prediction and stress detection. Enables detection of imbalanced nervous system states that precede illness or overtraining. More sophisticated than raw HRV for personalized adaptation signals.
- **How:** 1. Clean RR intervals (Task 5 pipeline already in place). 2. Segment RR into sleep stages (deep/REM preferred; Task Force recommends supine, quiet conditions). 3. Interpolate to 4 Hz and zero-pad to 256+ samples (Task Force guidelines). 4. Apply Welch periodogram (scipy.signal.welch) with nperseg=128, noverlap=64. 5. Integrate PSD over [0.04, 0.15] Hz (LF) and [0.15, 0.4] Hz (HF) bands. 6. Compute ratio LF/HF. Normalize by 5-min window to smooth transients. References: Task Force (1996) Eur Heart J; Malik et al. (1996) spectral power bands; Laborde et al. (2017) on sympathovagal interpretation caveats.
- **Data needed:** 30+ minutes of clean RR intervals per night (already captured at 1 Hz); requires at least 4–7 nights of prior data to establish personal baseline for deviation-from-baseline signals (follows recovery baseline pattern). With only 1 day, LF/HF is computable but lacks context; baseline needed for meaning.


### Post-Exercise Heart Rate Recovery (HRR)  _(difficulty: low)_
- **Signals:** HR (1 Hz); exercise session boundaries from the existing exercise-detection module
- **What:** The rate at which heart rate decelerates after a detected exercise bout (workout), measured in beats per minute per minute (bpm/min) over the first 60–120 seconds of recovery. Reflects rapid parasympathetic reactivation and vagal tone. Faster recovery (steeper negative slope) indicates better cardiac autonomic function and fitness; slower recovery is a mortality risk predictor.
- **Why:** Published literature (GE Healthcare, NIH) shows HRR is a strong independent predictor of overall mortality and cardiovascular risk, independent of resting HR and age. Garmin, Polar, and fitness wearables track HRR for readiness assessment. Reveals cardiac parasympathetic tone and training adaptations not captured by resting HR alone. Flags overtraining and poor autonomic recovery.
- **How:** 1. Identify exercise sessions from daily.py's detect_exercises() output (start, end, peak_hr). 2. Extract HR for 120 s post-exercise (from session end). 3. Fit linear regression: HR(t) = m·t + b, where t ∈ [0, 120] s. 4. HRR = |m| (magnitude of slope in bpm/s, convert to bpm/min = |m|·60). 5. Report HRR and fit R² for confidence. 6. Optional: use 1-min or 2-min gates to separate rapid parasympathetic reactivation from slower sympathetic withdrawal. Reference: Lauer et al. (1996) on HRR measurement; Cole et al. (2000) mortality risk; Huang et al. (2005) on parasympathetic lag.
- **Data needed:** At least 3–5 detected exercise bouts with post-exercise HR for reliable estimate. With 1 day of data, 2 auto-detected workouts are available (~16 min and ~8 min), sufficient to compute HRR but not to establish inter-session consistency. Pattern needs 1–2 weeks to show trends and personal baselines.


### Sleep Apnea Screening Index (AHI Proxy)  _(difficulty: high)_
- **Signals:** SpO2 (raw ADC red/IR), respiration rate (Welch estimate from resp field), gravity/motion (to exclude awake periods)
- **What:** A proxy for the Apnea–Hypopnea Index (AHI), estimated from wearable signals by detecting rapid SpO2 drops and respiratory rate variability. AHI is the number of apneic/hypopneic events per hour. Index >5 suggests mild OSA; >15 is moderate; >30 is severe. Enables home-based OSA screening without a polysomnography test.
- **Why:** OSA affects ~10% of the adult population, is linked to hypertension, arrhythmia, stroke, and sudden death, and is often undiagnosed. Wearable screening (Nature 2020, MDPI 2025, PLOS ONE) shows feasibility with PPG alone (correlation 0.61 to ground-truth polysomnography AHI). Early detection enables treatment (CPAP, positional therapy) and cardiovascular risk reduction. Oura and commercial wearables do not expose AHI; this fills a gap.
- **How:** 1. Segment nightly HR/SpO2/resp into 10–30 s windows. 2. Detect SpO2 drops ≥3% from window baseline (apnea signatures). 3. Measure drop duration and amplitude; count events. 4. Detect respiratory rate drops or pauses (resp entropy collapse or rate <6 bpm for >10 s = apnea). 5. Align temporal clustering of drops with arousal proxies (HR spike, motion from gravity). 6. Synthesize: AHI_proxy = (count_SpO2_drops + count_RR_pauses) / sleep_hours. 7. Validate against held-out data or published wearable studies (RMSE ~5 events/hr). References: Fonseca et al. (2020) on SpO2 drop scoring; Pepin et al. (2022) on automated OSA detection; AASM hypopnea definition (Ruehland et al. 2009).
- **Data needed:** 7+ nights of sleep to calibrate drop thresholds and establish personal baseline SpO2 (current data: 1 night with spo2_pct=86.6%, implausibly low if literal, suggesting uncalibrated ADC). Requires SpO2 calibration (fit_spo2 routine exists but needs WHOOP ground-truth). Motion/gravity validation data to exclude daytime false positives. Without calibration, current spo2 values unreliable for OSA screening.


### Illness/Fever Detection (Skin Temperature Deviation + Pattern)  _(difficulty: medium)_
- **Signals:** Skin temperature (raw ADC); HR (secondary: tachycardia correlate); possibly respiration rate anomaly
- **What:** An infection-risk flag triggered by sustained elevation of skin temperature deviation above personal baseline. Uses template matching and cumulative anomaly scoring to detect febrile and sub-febrile patterns associated with infection (COVID, influenza, bacterial). Elevation of 0.5–1.5°C above baseline, especially if multi-day duration, is clinically actionable.
- **Why:** Stanford/UF research (2017–2022) demonstrates wearables can detect infection onset 1–2 days before symptom onset. Published in MDPI Sensors (2024) for COVID surveillance. Oura Ring surfaces skin-temp deviation for this purpose. Enables early intervention (test, quarantine) and longitudinal epidemiology. Complements clinical thermometer with continuous passive monitoring.
- **How:** 1. Compute skin_temp_deviation_c as in daily.py: deviation = slope · (tonight_raw − baseline_raw), where baseline is trailing-30 d median. 2. Threshold: flag if |deviation| >0.5°C and sustained >2 hours or recurring >2 times per night over 2+ consecutive nights. 3. Pattern: template-match anomalies (Gaussian convolution or Hidden Markov Model) against historical baseline circadian curve; deviation from expected curve shape = infection risk. 4. Score: cumulative z-score over N-day window (e.g., 7 days); score >2.5σ = alert. 5. Validate: report only if skin_temp_dev_c is successfully calibrated (fit_skin_temp run with WHOOP ground-truth). References: Steinhubl et al. (Stanford, 2018) on Fitbit fever detection; Rosenberg et al. (UF 2022) on continuous monitoring; MDPI 2024 syndromic surveillance.
- **Data needed:** 14–30 nights of personal baseline skin temperature to establish circadian curve and inter-night variability. Current state: 1 night with skin_temp_dev_c=null (insufficient data for baseline). Requires WHOOP calibration before threshold tuning. No fever events in current 1-day window to validate.


### Pulse Wave Velocity (Arterial Stiffness Proxy)  _(difficulty: high)_
- **Signals:** HR (1 Hz); SpO2 red/IR ADC (PPG fiducial detection)
- **What:** A non-invasive estimate of arterial stiffness via pulse arrival time (PAT) between ECG R-peak (approximated by HR beat start) and PPG fiducial (red/IR peak). PWV ∝ 1/√PAT. Lower PWV (~6–8 m/s in youth) is healthier; >10 m/s signals vascular aging and cardiovascular risk. Proxy enables tracking age-related arteriosclerosis and hypertension without cuff BP.
- **Why:** PWV is the gold-standard non-invasive biomarker of arterial stiffness and independent cardiovascular-risk predictor (European Society of Hypertension). Recent advances (Nature 2025, USPTO patents) show PPG-derived PAT correlates strongly with carotid-femoral PWV. Enables mass-market longitudinal vascular aging tracking without specialized equipment. Garmin includes 'vascular age' estimates; Oura does not expose it. Flags hypertension, atherosclerosis risk.
- **How:** 1. Detect HR beat times from 1 Hz HR samples (moving-average HR to estimate instantaneous beat occurrence; or upsample + find local maxima if raw waveform available). 2. Detect PPG fiducial points from red/IR signals: find peaks in red channel post-detrending (fiducial = PPG systolic upstroke or foot). 3. Compute pulse arrival time (PAT) = time delay from HR beat to PPG peak (typically 10–100 ms, varies with BP and stiffness). 4. PWV ≈ body_length / PAT or use calibrated formula (Mukkamala et al., 2015). 5. Smooth PAT over nightly window (60–120 samples) to reduce noise. 6. Track trend over weeks to detect arterial stiffening. Reference: Mukkamala et al. (2015) IEEE review; Nature 2025 on machine-learning PWV estimation; Mendelson & Ochs (1988) on reflectance PPG.
- **Data needed:** High-quality PPG red/IR samples (1 Hz minimum; benefit from 10+ Hz if available). Current data: red~587, ir~585 (weak AC signal indicates noisy channel or off-wrist contact). Requires at least 7–30 nights of data to establish personal baseline and track drift. PAT is sensitive to BP, posture, and breathing; need sleep-normalized window (deepest sleep stages) to minimize confounders.


### Cardiac Ectopic Burden (PVC/Ectopic Beat Count)  _(difficulty: medium)_
- **Signals:** RR intervals (beat-to-beat timing); HR waveform features (if available from PPG demodulation)
- **What:** Detection and quantification of premature ventricular contractions (PVCs) or premature atrial contractions (PACs) as irregular inter-beat intervals that deviate >2σ from nightly mean RR. Ectopic burden (count per hour or percentage of total beats) reflects arrhythmia risk. Elevated ectopic count (>100 PVCs/day) is associated with sudden cardiac death and atrial fibrillation risk in some populations.
- **Why:** Apple Watch and academic studies (PLOS ONE 2024, IEEE 2025) show PPG can detect 60%+ of ectopic beats detected on ECG. Research validates use in remote monitoring for arrhythmia screening and progression tracking. Complements rate-based metrics (resting HR, HRV) with rhythm regularity. High ectopic burden correlates with stress, caffeine, sleep disruption, and cardiac disease; enables early intervention.
- **How:** 1. Extract RR intervals from rr field. 2. Compute nightly mean(RR) and std(RR); filter out artefacts (RR <300 or >2000 ms). 3. Flag as ectopic: any RR that is >2σ_RR away from mean (or <0.8·mean or >1.3·mean for stricter thresholds used in AF detection). 4. Manually review flagged beats (PPG morphology inspection if waveform available); exclude artefacts (motion, signal dropout). 5. Count ectopic beats per sleep session; normalize to ectopic_burden = count / (sleep_duration_min / 60). 6. Report ectopic_count and burden_per_hour. Reference: Nemati et al. (2016) on PPG ectopic detection; Apple Watch Afib study; Goldberger et al. (2000) on PVC prognostic value.
- **Data needed:** ≥1 full night of clean RR intervals (available in current 1-day window). Ectopic count is interpretable with even 1–2 nights, but burden rate and trend require 7+ nights to establish personal baseline (some people have frequent benign ectopy; others have pathologic burden). With current data: resting_hr=53 bpm, avg_hrv=75 ms—no flags visible but RR data needed to confirm no ectopy.


### Cortical Arousal Index (Movement + HR Variability)  _(difficulty: medium)_
- **Signals:** Gravity (accel L2-delta, 1 Hz); HR instantaneous variability (RR interval deviations); optional respiration rate anomaly (resp field)
- **What:** A proxy for sleep-stage transitions and micro-arousals (brief cortical awakenings <15 s) using multimodal fusion of accelerometer motion intensity (gravity L2-delta) and instantaneous HR-variability spikes. Arousal index = count of detected arousals per hour of sleep. Elevated arousal index (>10–15/hour) indicates fragmented sleep, sleep apnea, or periodic breathing.
- **Why:** Published research (Nature 2025, IEEE Pulse) shows multimodal arousal detection outperforms single-sensor approaches. Movement is the strongest signal for arousal (cortical arousals trigger micro-movements). Complements sleep-stage classification (which is weak on deep/light separation per daily.py comments). Arousal fragmentation is clinically linked to hypertension, cognitive decline, and quality-of-life measures. Polysomnography standard but non-portable; wearable proxy enables home monitoring.
- **How:** 1. Segment nightly gravity stream into 5–10 s windows. 2. Compute L2-norm delta: Δ_g[i] = ||g[i] − g[i-1]|| (change in 3D gravity magnitude). 3. Detect motion spike: Δ_g > threshold_motion (e.g., 95th percentile of baseline stillness, ~0.05–0.1 g for sleep). 4. Parallel: compute instantaneous RR variability via rolling z-score of RR intervals or point-process HRV (Barbieri et al. 2005). Flag HR spike coincident with motion spike (within ±3 s). 5. Cluster motion+HR events temporally; merge clusters <15 s apart (single arousal). 6. Arousal_index = count_arousals / sleep_hours. 7. Cross-validate via disturbances field in sleep.py (existing post-onset wake count). Reference: te Lindert & Van Someren (2013) accelerometer epoch analysis; Patwardhan et al. (2025) on multimodal arousal detection.
- **Data needed:** Multiple nights (≥3–5) of gravity + RR data to calibrate motion threshold (inter-night stillness varies with sleep position, strap fit, environmental temperature). Current 1 night insufficient for personal baseline. Requires validation against polysomnography-confirmed arousals (not available in this project) or surrogate (disturbances count; current night shows 9 disturbances, matching observed ~1 arousal per 30 min sleep ≈ 18/hour if accurate).


### Cumulative Nocturnal SpO2 Burden / AUC Below Threshold  _(difficulty: medium)_
- **Signals:** SpO2 (raw red/IR ADC via spo2_percent_window), sleep windows from sleep-detection module
- **What:** A continuous integration of hypoxemia: the area-under-curve (AUC) of SpO2 time spent below a personal threshold (e.g., 90%, 88%, or 85%) during sleep, measured as %-minutes per night. High burden (>50 %-min/night at 90%) indicates recurrent desaturation, which correlates with sleep apnea severity, pulmonary disease, and nocturnal hypoxemia risk.
- **Why:** SpO2 burden (time-integral hypoxemia) is more clinically relevant than single low values because it captures cumulative oxygen debt. AASM sleep medicine and wearable apnea literature emphasize burden as a severity proxy. Enables discrimination between benign dips and pathologic hypoxemia. Pulmonary and cardiac patients are prime users. Oura exposes SpO2 and breathing-disturbance index; quantifying burden adds specificity.
- **How:** 1. Compute spo2_pct for nightly SpO2 samples as in daily.py's _nightly_signals: ratio-of-ratios window over red/IR ADC, clamped [70, 100]. 2. Set threshold T (e.g., 90% for clinical hypoxemia, or 95% for continuous sub-optimal). 3. For each 1-sample (1 s) in sleep window: if spo2 < T, accumulate deficit = (T − spo2); else 0. 4. AUC_burden = sum_deficits / sleep_duration_sec. 5. Alternative: time_below_threshold = count(spo2 < T) / sleep_duration_min (%-min, more intuitive). 6. Report both AUC and time_percent. Validate calibration against WHOOP or transcutaneous SpO2 reference. Reference: Ruehland et al. (2009) AASM scoring; Fonseca et al. (2020) on wearable SpO2 burden.
- **Data needed:** Calibrated SpO2 ADC-to-% conversion (current default units.py is un-calibrated; fit_spo2() requires WHOOP ground-truth data). Current 1-night spo2_pct=86.6% is implausibly low if true (normal is 94–99% during sleep); suggests either uncalibrated defaults or off-wrist contact. Requires 7+ nights of validated SpO2 to establish personal baseline and thresholds. Threshold choice depends on clinical question (apnea screening vs. pulmonary disease monitoring).


### Vo2max / Aerobic Capacity Estimate (Resting HRV + Age-Like Proxy)  _(difficulty: medium)_
- **Signals:** HR (resting nightly mean, peak from workouts); RR intervals (nightly HRV / RMSSD); activity/motion (exercise detection already in place)
- **What:** A machine-learning or Karvonen-formula-based estimate of maximal aerobic capacity (VO2max in ml/kg/min) derived from resting HRV, resting HR, and observed peak HR during exercise. VO2max is the gold standard for aerobic fitness. Wearable estimates enable longitudinal fitness tracking without lab spirometry.
- **Why:** VO2max is the strongest predictor of longevity and cardiovascular health (Framingham, INTERHEART). Garmin Fenix 6 achieves MAPE=6.85% on VO2max estimation vs. lab gold-standard (Cortez et al.). Oura Ring exposes VO2max. Enables fitness progression tracking, training zone prescription, and early detection of detraining. Single estimate is noisy but week-by-week trends are meaningful.
- **How:** Method A (Legacy Karvonen): VO2max ≈ 15.3 · (HRmax / resting_HR). With personalized HRmax (already estimated in daily.py from p99.5), plug in nightly resting HR from recovery baseline. Method B (Regression on features, preferred): Train on WHOOP exports if available: VO2max ∝ resting_HRV^0.5 + (HRmax − resting_HR) / age_proxy. Age proxy = a 'physiological age' derived from HR variability under load or resting HR creep. Without WHOOP labels, use published regression from Garmin (Cortez et al. 2021) as a starting point. Method C (VO2reserve per workout): For each detected workout, compute HRR % = (peak_HR − resting_HR) / (HRmax − resting_HR); integrate across exercise window as surrogate training stimulus; regress against known VO2max improvement rates (literature: ~5% per month hard training). References: Karvonen et al. (1957); Tanaka et al. (2001) age-HRmax; Cortez et al. (2021) on Garmin Fenix 6 validation.
- **Data needed:** 14–30 days of resting HR, HRV, and >3 peak-exertion workouts to establish fitness baseline. Current data: 1 day with resting_hr=53, avg_hrv=75 ms, 2 workouts (~peak 105, 98 bpm; resting ~53). Single estimate possible but confidence is low; needs 2–4 weeks of consistent morning baselines + structured workouts. Without WHOOP ground-truth labels, accuracy is limited to ~7% MAPE (Garmin benchmark); higher with calibration.


### Lactate Threshold (Heart Rate at Deflection Point) Proxy  _(difficulty: high)_
- **Signals:** HR (1 Hz during workouts); RR intervals (HRV collapse as a detector); optional cadence/pace if available
- **What:** An estimate of the intensity (expressed as % HRmax or absolute HR bpm) where lactate accumulates and blood pH drops—the aerobic-anaerobic boundary. Garmin's 'Lactate Threshold' feature uses HRV collapse + HR smoothness; automated detection during structured intervals. Estimated LT HR informs zone training and race pacing.
- **Why:** Lactate threshold is a physiologically meaningful training intensity marker. Garmin automated LT detection (as of 2023) eliminates need for guided lab tests. Literature (Cortez et al., MDPI 2021) shows wearable LT estimates valid within 7.52% MAPE on speed at LT. Enables personalized zone training without sport-science lab. Threshold shifts with training (rises = fitness gain).
- **How:** Method A (HRV-collapse detector, simplest): During a workout, monitor RMSSD over 30–60 s rolling windows. LT ≈ HR at which RMSSD sharply drops (typically 20–50% decline) and does not recover until recovery. Smooth with median filter to reduce noise. Method B (HR smoothness + curve deflection): Compute HR curvature (d²HR/dt²) during ramping workout; detect inflection point (concavity change from concave up to concave down, or vice versa). LT ≈ HR at inflection. Method C (Multi-feature logistic): Combine RMSSD collapse, HR variability drop, and respiration-rate acceleration into a classification threshold (threshold probability >0.7 = LT crossed). Validate against WHOOP-tagged workouts if available. Reference: Seiler et al. (2006) on HRV at threshold; Billat et al. (2003) on LT detection from time-domain HRV.
- **Data needed:** ≥3–5 structured workouts with ramping intensity or continuous exertion (20+ min duration with clear intensity change). Current data: 2 short workouts (~8–16 min) without ramping; likely too short for reliable LT detection. Structured interval sets (e.g., 10 min steady → 5 min hard → 5 min easy) ideal but not present. Requires 2–4 weeks of diverse workout data to establish personal threshold HR and RMSSD deflection point.


### Sleep Debt / Sleep Need Deficit Accumulation  _(difficulty: low)_
- **Signals:** Daily sleep duration (total_sleep_min from daily metrics); optionally sleep efficiency and stage distribution (deep/REM/light)
- **What:** A rolling estimate of cumulative sleep deficit (sleep obtained vs. individually needed) over 7–14 days. Assumes a personal sleep need (e.g., 7–9 h from age/fitness models) and accumulates any shortfall. High debt (>5 h cumulative over 7 d) is linked to cognitive decline, injury risk, and illness. Enables early intervention (schedule recovery sleep).
- **Why:** Sleep debt is a novel metric not standard in WHOOP, Oura, or Garmin. Literature (Czeisler & Gooley, Prog Brain Res 2011; Walker, Why We Sleep) emphasizes cumulative debt drives cognitive and immunological deficits. Enabled by project's already-computed daily sleep summaries. Personalized sleep need can be inferred from age and activity level or empirically from longest night in a baseline period.
- **How:** 1. Estimate personal sleep need: N_need_h ≈ 7.5 h for adults (or empirically: median of last 30 nightly values, capped at [6, 9]). 2. For each day, compute deficit = max(0, N_need_h − total_sleep_h). 3. Accumulate rolling 7-day and 14-day sums: debt_7d = sum(deficit[−7:]), debt_14d = sum(deficit[−14:]). 4. Flag if debt_7d >5 h (high) or >7 h (critical). 5. Optionally weight by sleep efficiency (poor-quality sleep compounds debt faster). Reference: Klerman & Gershengorn (2016) on sleep debt kinetics; Van Dongen et al. (2003) on cognitive decline threshold.
- **Data needed:** 14–30 nights of sleep data to establish personal sleep need baseline. Current data: 1 night with total_sleep=393.5 min (~6.56 h), below the 7.5 h benchmark, but insufficient to infer personal need. Needs 2–4 weeks of sleep tracking to separate genuine chronic deficit from single-night variation.


### Resting Metabolic Rate Proxy (HR + Skin Temp + Activity Baseline)  _(difficulty: low)_
- **Signals:** Resting HR (nightly minimum or 30-min mean during deep sleep); skin temperature (absolute and deviation); activity/gravity (daytime motion intensity to adjust basal upward)
- **What:** An estimate of daily resting metabolic rate (kcal/day) derived from personalized resting HR (basal metabolic rate correlates with HR at rest), nightly skin temperature (higher temp = higher metabolism), and activity (basal + activity-adjusted). Enables energy expenditure tracking without food diary or lab calorimetry.
- **Why:** Metabolic rate is central to weight management, performance, and health. WHOOP estimates calories but uses proprietary methods. Wearable RMR estimation could enable personalized nutrition and training adjustments. Oura does not expose metabolic rate. Literature (Harris-Benedict, Mifflin-St Jeor, and wearable validation) shows HR-based RMR estimates are feasible and correlate ~0.6–0.7 with calorimetry.
- **How:** Method A (Simple: Mifflin-St Jeor + HR adjustment): Baseline RMR = 10·weight_kg + 6.25·height_cm − 5·age + 5 (men) or −161 (women). Adjust by nightly resting HR deviation: RMR_adj = RMR · (1 + 0.01·(RHR_tonight − RHR_personal_baseline) / RHR_baseline). Activity adjustment: total_daily_energy = RMR_adj · (1 + activity_factor), where activity_factor ≈ gravity_integral_daytime / gravity_integral_sleep. Method B (Regression on features, preferred): Collect 14+ days of resting HR, skin temp, and weight (or waist circumference proxy). Regress RMR vs. resting HR, skin temp, age; use leave-one-out CV to validate. Reference: Mifflin et al. (1990) RMR equations; Johannsen et al. (2010) on wearable HR accuracy for RMR.
- **Data needed:** User demographics (age, weight, height, sex) + 7–14 days of consistent resting HR and nightly skin temp. Current data: weight/height not in codebase; 1 night with resting_hr=53 bpm (low, suggests good fitness or measurement noise), skin_temp_dev_c=null (no calibration). Without user anthropometry and calibration, cannot compute absolute RMR. Trend tracking possible with 2–4 weeks of resting HR/temp alone.
