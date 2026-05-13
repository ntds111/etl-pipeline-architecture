# Pulsefit — Analysis Results

---

## Q1: Blended CPI per paid channel

**Reporting currency:** USD (multi-currency spend converted at static period rates).
**Denominator:** ad-platform reported installs, blended across all countries, campaigns, and dates.

| Channel          | Total spend (USD) | Installs | CPI (USD)   | Rank                |
|------------------|------------------:|---------:|------------:|---------------------|
| Google Ads       | $58,339           | 4,101    | **$14.23**  | 1 — cheapest        |
| Facebook / Meta  | $48,811           | 2,655    | **$18.38**  | 2                   |
| TikTok           | $36,657           | 1,784    | **$20.55**  | 3                   |
| Apple Search Ads | $43,542           | 1,888    | **$23.06**  | 4 — most expensive  |

---

## Q2: Funnel conversion per channel

**Population note:** the funnel is built on CRM-registered users (`dim_user`, 500 total) — users
who created an account. Ad-platform installs (10,428 across paid channels) are a different
population: CRM captures only 2–5% of paid installs per channel. The two cannot be combined
into a cost-per-subscriber figure.

**Funnel methodology:** reach-based — a user is counted at each step if they ever triggered
that event, regardless of order. `signup_complete` is shown as a count but is **not used as a
gate**: the app is freemium. Users can work out and subscribe without completing a formal
signup — 166 worked out with no signup event and 21 subscribed with no signup event. Using
signup as a required step would exclude real paying customers. The primary metric is
**overall conversion: CRM user → subscription**.

**Attribution:** single-touch from CRM `channel` field, assigned once per user.

| Channel          | CRM users | Signed up | Workout started | Workout completed | Subscribed | Overall conv% | CPI (USD) | Flag                       |
|------------------|----------:|----------:|----------------:|------------------:|-----------:|--------------:|----------:|----------------------------|
| TikTok           |        77 |        40 |              60 |                47 |         11 |     **14.3%** |    $20.55 | —                          |
| Apple Search Ads |        68 |        32 |              47 |                41 |          8 |     **11.8%** |    $23.06 | —                          |
| Organic          |        80 |        37 |              55 |                47 |          9 |     **11.3%** |         — | —                          |
| Google Ads       |       100 |        41 |              73 |                55 |         10 |     **10.0%** |    $14.23 | cheap CAC, poor conversion |
| Referral Program |        53 |        17 |              39 |                29 |          4 |      **7.5%** |         — | —                          |
| Facebook / Meta  |       122 |        62 |              78 |                81 |          6 |      **4.9%** |    $18.38 | cheap CAC, poor conversion |

**Google Ads and Facebook / Meta** are both flagged: below-median CPI and below-median
end-to-end conversion (threshold = median across the four paid channels).
- **Facebook** has the most CRM users (122) and the lowest conversion (4.9% — 6 subscribers).
  It looks cheap at $18.38 CPI but produces the worst downstream results.
- **Google Ads** is the cheapest channel at $14.23 CPI but converts only 10.0% of CRM users,
  placing it below the paid-channel median on both dimensions.

---

## Q3: Surprising findings

### Finding A — `install_date` is the CRM entry date, not the app install date

53% of all events (1,633 / 3,080) are timestamped *before* the user's `install_date`,
with a consistent ~45-day average gap across all seven event types and all six channels.
First instinct: data error. On investigation the gap is too uniform to be noise — a random
entry error would not produce the same ~45-day pattern across every event type.

**Root cause:** the app is freemium. Users install and use the app for free for ~45 days on
average before creating a CRM account. The CRM records that signup moment as `install_date`.
Free-tier activity leaves no CRM footprint until the user signs up.

**Why it matters:** any time-to-convert or cohort analysis anchored on `install_date` will be
systematically ~45 days too short. The correct anchor is the first `install` or `app_open`
event from `fact_events`. This also explains the Q2 freemium paths — users active before
CRM registration have no signup event on record.

> **Question for data producer:** is `install_date` populated at signup completion,
> and is there a separate first-app-open timestamp available from the analytics tool?

---

### Finding B — subscription data from two sources does not reconcile

Two independent sources record subscriptions:
- **`subscriptions.json`** — payment dump from Stripe (named in the task as one of the three manual sources)
- **`events.csv`** — product analytics stream, specifically the `subscription_started` event

They barely overlap.

| Source                                                                         | Users |
|--------------------------------------------------------------------------------|------:|
| `subscriptions.json` (Stripe) only — no `subscription_started` event          |    92 |
| Both `subscriptions.json` and `events.csv`                                     |     8 |
| `events.csv` only — no matching row in `subscriptions.json`                   |    40 |
| **Total unique subscribers across both sources**                               |   140 |

| `subscriptions.json` data completeness    | Value    |
|-------------------------------------------|----------|
| Records with `start_date` populated       | 3 (2.7%) |
| Records with `end_date` populated         | 0 (0.0%) |

Only 8 users can be verified by both sources.
97.3% of Stripe records have no `start_date`. Churn, LTV, and renewal-rate
analysis cannot be built from this data without source reconciliation.

> **Questions for data producer:**
> 1. Are `start_date` / `end_date` available in Stripe and simply not exported here?
> 2. Why do 92 users appear in the subscriptions table with no `subscription_started` event?
> 3. Why do 40 users have a `subscription_started` event but no row in the subscriptions table?
