# Design decisions

- **Python + PostgreSQL:** retain the existing stack; Python handles files and
  orchestration while SQL keeps transformations close to the data.
- **Raw → build → star:** separate source fidelity, cleaning, and reporting so
  rejected records and reconciliation remain inspectable.
- **Key/hash-based raw upserts:** avoid reinserting unchanged data while allowing
  corrected source records to update supported keys.
- **Full build/star refresh:** simple and repeatable for this small sample;
  incremental downstream models would add unnecessary state management.
- **Validation before promotion:** build quality and integrity checks gate star
  creation; post-star checks are recorded for review.
- **Local files and JSON summaries:** keep inputs and run results easy to inspect
  without adding an orchestrator, container stack, or logging service.
- **Plain scripts and standard tools:** keep existing imports and script entry
  points, use libpq environment settings, and avoid packaging/config frameworks.
- **Cloud architecture as a concept:** preserve the AWS diagram without implying
  that deployment code or production operational guarantees are included.
