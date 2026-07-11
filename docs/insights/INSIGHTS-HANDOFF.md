# Insights handoff: wearable biometric analysis (WHOOP 4.0 project → Oura ring project)

This is a handoff from a completed project that reverse-engineered a WHOOP 4.0 band, collected its
raw 1 Hz biometrics locally, and built a self-hosted pipeline that derives recovery, sleep, strain,
and workout metrics. The device work (BLE, the WHOOP framing protocol) does not transfer to an Oura
ring. The **data and analysis learnings do**, because both devices measure the same underlying
signals (PPG-derived heart rate and HRV, body temperature, motion, SpO2, respiration) and derive the
same family of metrics (sleep staging, a readiness/recovery score, activity load).

Read this file first. The five companion docs in this folder have the full detail; this one tells
you what to take from them and what was actually proven versus assumed.

## The most valuable structural idea: separate raw storage from derived metrics

The pipeline stored the decoded 1 Hz streams as immutable rows in a time-series database, and computed
every metric (recovery, sleep, strain, calories) as an idempotent, re-runnable derivation on top. A
single `compute_day(device, date)` re-derived a day from the stored raw whenever called.

Why this matters for an Oura RE project: you collect the raw signal once, then iterate on the analysis
forever without re-collecting. You can A/B a new algorithm by recomputing the same stored history under
"before" and "after" code and diffing the outputs. Build this separation from day one. The one thing it
cannot fix is a signal that was never sampled densely enough (see respiration below).

## Metric-by-metric: what is trustworthy, what is not, and why

Each verdict below was reached on real collected data, not theory. Confidence is marked.

- **Sleep duration and efficiency: trustworthy.** Validated against an Apple Watch Ultra 3 on the same
  night, within about 3 percent (255 vs 262 minutes). Onset/offset detection was good. The user judged
  the WHOOP window more accurate than the Apple Watch, which tends to over-extend the edges by counting
  quiet in-bed time. **Lesson for Oura: cross-check duration against a reference wearable; it is likely
  your most reliable derived metric.**

- **Sleep stages (deep/REM/light): broken, do not trust single nights.** Our open-source stager
  reported implausible splits (about 91 percent light every night, and 0 minutes deep on a 7.6 hour
  night). The same night the Apple Watch showed a normal architecture (71 minutes deep, 53 REM).
  Literature ceiling for non-EEG staging is around 72 percent accuracy (Walch 2019). **Lesson: staging
  from PPG + motion is genuinely hard; validate against a reference and treat the stage breakdown as
  approximate. Oura markets stage accuracy heavily, so expect to work hard here and calibrate against
  ground truth.**

- **HRV (RMSSD): formula is standard, the trap is elsewhere.** RMSSD per the Task Force 1996 standard
  is correct and simple. Two real findings: (1) PPG underestimates RMSSD by roughly 3 to 4 ms versus
  ECG, a fixed bias worth knowing. (2) We assumed we would need an artifact-density gate (a single bad
  beat can inflate RMSSD hugely), built the case for one, then measured our own data and found artifact
  rates of only 0.2 to 0.4 percent, well under the roughly 0.9 percent reliability threshold in the
  literature. The gate would have changed nothing. **Lesson: measure your own artifact rate before
  assuming you need correction. Use the Kubios / Lipponen-Tarvainen 2019 method to detect and correct
  artifacts, but do not let a clean signal convince you the pipeline is the problem.**

- **The real driver of noisy HRV/readiness was window selection, not artifacts.** The reported nightly
  HRV came from a "last slow-wave-sleep window" (mimicking WHOOP). That sub-window landed on different
  segments each night and swung a lot (43 to 88 ms), while the whole-night RMSSD was far steadier (44 to
  64 ms). **Lesson: how you window the night matters as much as the cleaning. Whole-night is steadier;
  a physiologically-motivated sub-window is noisier but arguably more meaningful. This is a real design
  choice, not an obvious win either way.**

- **Recovery / readiness: a z-score + logistic composite, and it needs a personal baseline.** The score
  standardizes tonight's HRV, resting HR, respiration, and sleep against the person's own rolling
  baseline, weights them (HRV dominant at 0.60), and squashes to 0 to 100. It is honest about
  cold-start: it returns null until at least 4 valid baseline nights exist, and is not fully trusted
  until about 14. **Two hard-won lessons: (1) a readiness score is only meaningful relative to a
  personal baseline, so budget 2+ weeks of wear before the number stabilizes; the magnitude swings
  wildly early because the baseline spread is poorly estimated. (2) Watch the cold-start edge: a bug let
  the very first night (zero baseline) fall through to a sleep-efficiency-only score that looked like a
  real 84 percent recovery but contained no HRV at all. Gate the score on actually having the dominant
  input, and prefer returning null over a fake number.** Oura's Readiness is the same concept and will
  have the same baseline-maturity and cold-start considerations.

- **Body temperature: use as a deviation from baseline, never absolute.** Skin temperature came as raw
  uncalibrated ADC counts; only the deviation from a trailing personal median was meaningful, and only
  as a trend. **Lesson: this is directly relevant to Oura, which leans on temperature-trend for illness
  and cycle detection. Model it as nightly deviation from a personal baseline, not degrees.**

- **SpO2 and respiration: know your sampling-rate ceiling.** SpO2 was uncalibrated ratio-of-ratios ADC
  (and carries a documented skin-tone bias in the literature). Respiration computed from a 1 Hz stream
  is physically inadequate; a real respiratory rate needs roughly 100 Hz sampling, and no amount of
  re-analysis recovers what was never sampled. **Lesson: identify each signal's true sampling rate
  early. Some metrics are back-computable from stored raw and some are not; respiration is the classic
  not-recoverable case.**

- **Calories: blocked on anthropometry, and the formula choice matters.** Needs height, weight, age,
  sex. Harris-Benedict is about 32 percentage points less accurate than Mifflin-St Jeor for the resting
  component; prefer Mifflin-St Jeor. **Lesson: collect the user profile; pick the better-validated
  formula.**

## Data-collection gates (how many nights before a metric is real)

Metrics do not become trustworthy at the same rate. Rough thresholds we settled on: recovery becomes
real at about 4 nights, personal baselines at about 14 to 30 nights, and a personalized max-heart-rate
estimate needs about 90 days of wear to capture genuine peak efforts. **Lesson: instrument the
"calibrating" state explicitly and show it, rather than emitting confident numbers on day one.**

## Validation methodology that worked

1. Cross-check against a second reference wearable on the same night (Apple Watch here). It separated
   "our duration is good" from "our stages are broken" instantly.
2. Measure signal quality on your own collected data (artifact rate, coverage) before building
   corrections for problems you may not have.
3. Keep raw immutable and recompute idempotently, so any algorithm change can be A/B'd against the full
   stored history.

## The companion docs in this folder

- `2026-06-02-analysis-audit.md` — per-metric audit: what each algorithm computes, code correctness,
  data sufficiency, and 12 proposed new metrics.
- `2026-06-02-analysis-audit-literature-addendum.md` — deeper cited literature (RMSSD, Kubios, sleep
  staging ceilings, SpO2 bias, Mifflin-St Jeor).
- `2026-06-02-proposed-fixes-and-eval-plan.md` — four candidate analysis fixes with an A/B evaluation
  plan; includes the later finding that the HRV volatility was window selection, not artifacts, and the
  recovery cold-start bug writeup.
- `2026-06-03-whoop5-feasibility.md` and `2026-06-03-android-openwhoop-feasibility.md` — device/platform
  feasibility studies. WHOOP-specific and mostly not transferable to Oura, included for completeness.

## What did NOT transfer (so you do not go looking for it)

The BLE reverse-engineering, the WHOOP framing protocol (opcodes, CRCs, the type-47 record layout), the
strap sync/offload mechanics, and the iOS collection app are all WHOOP-hardware-specific. An Oura ring
has its own transport, its own packet format, and its own pairing/auth story that you will need to
reverse-engineer separately. Only the analysis-and-data layer above carries over.
