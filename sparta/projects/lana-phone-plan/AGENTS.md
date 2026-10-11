# Agent instructions

The executor is `executor.mjs` (deterministic, no model). `executor-v1.mjs` is the recorded baseline; do not fix it. Edit missions and checks through `make-missions.mjs`, never by hand, and keep checks out of the executor's inputs. Keep connector traffic on `WORLDS_BASE_URL` with `WORLDS_API_KEY`. Billing writes use a stable Idempotency-Key per action_id.
