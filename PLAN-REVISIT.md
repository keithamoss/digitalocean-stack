# Auto-Redeploy Revisit Plan

## Purpose

This document captures the current implementation review for auto-redeploy, decisions already selected, and the remaining choices to finalize before making code changes.

## Current State Snapshot

Implementation exists and is operational across:
- `auto-redeploy/auto-redeploy.sh`
- `auto-redeploy/auto-redeploy.service`
- `auto-redeploy/auto-redeploy.timer`
- `auto-redeploy/install.sh`
- Target configs under `orchestration/demsausage/{staging,production}/auto-redeploy.conf`

## Review Findings (Gaps vs PLAN.md)

### High priority

1. **Missing hard runtime ceiling in systemd service**
   - `auto-redeploy.service` currently lacks `RuntimeMaxSec=15min`.
   - Risk: a hung run can block subsequent timer cycles.

2. **Trigger policy differs from plan intent**
   - Current script skips redeploy when `head_sha` equals last deployed SHA.
   - Plan intent was run-id idempotency (`deployed_run_id`) rather than SHA dedupe.

   Why this matters in practice:
   - A new successful CI run can produce different runtime artifacts or image metadata even when source SHA is unchanged (e.g., dependency freshness, rebuild side effects, image republish).
   - SHA-based dedupe can suppress those deployments.
   - Run-id idempotency preserves exactly-once behavior per successful workflow run while still preventing duplicate deploys of the same run.

### Medium priority

3. **Deployment path coupled to nginx refresh for all targets**
   - Script unconditionally runs `orchestration/nginx.sh --skip-download` in deployment sequence.
   - This reduces generic applicability for future non-nginx targets.

   Practical ways to address this:
   - **Option A (minimal change):** Keep current behavior for now and explicitly document that auto-redeploy currently assumes nginx-based workloads.
   - **Option B (recommended):** Add a target config flag (for example `REFRESH_NGINX=true|false`) so each target controls whether nginx refresh is part of its deploy.
   - **Option C (most generic):** Add a per-target post-deploy hook path (for example `POST_DEPLOY_HOOK="${STACK_DIR}/orchestration/nginx.sh --skip-download"`) and execute it only when configured.
   - Suggested path now: Option B, because it is low risk and keeps behavior explicit per target.

4. **Shell strictness missing `-e`**
   - Script uses `set -uo pipefail`.
   - Recommend `set -euo pipefail` with explicit handling where non-fatal behavior is intended.

5. **Watch timeout default mismatch**
   - Script/README default is 15 minutes.
   - Plan default says 10 minutes.

   Decision direction:
   - Keep runtime default at 15 minutes.
   - Align PLAN.md to 15 minutes.

6. **Cloudflare purge currently non-fatal on missing env/values**
   - If purge is enabled but env file/keys are missing, script warns and continues.
   - Plan expectation can be interpreted as stricter when purge is enabled.

### Low priority

7. **Legacy files still present**
   - `demsausage-staging-redeploy.sh`
   - `demsausage-production-redeploy.sh`
   - `orchestration/demsausage-staging.sh`
   - `demsausage-staging.yml`
   - `demsausage-production.yml`

## Decisions Already Selected (from rich UI)

- **Immediate implementation work:** no action yet
- **Trigger policy:** Run ID based (plan behavior)
- **Cloudflare strictness:** If purge is enabled and creds are missing, fail deployment
- **Rollout:** staging first, observe 24 hours, then production
- **Legacy cleanup timing:** remove now in same change set
- **Docs alignment:** update PLAN and README immediately
- **Change window:** no schedule yet

Additional decisions from review walk-through:
- **Item 1:** agreed
- **Item 2:** confirmed — use `deployed_run_id` as the deploy trigger/idempotency gate
- **Item 3:** confirmed — adopt Option B (`REFRESH_NGINX=true|false` per target)
- **Item 4:** agreed
- **Item 5:** align PLAN.md to 15 minutes (not script down to 10)
- **Item 6:** agreed
- **Item 7:** agreed

## Proposed Change Bundle

1. Add `RuntimeMaxSec=15min` to `auto-redeploy/auto-redeploy.service`.
2. Switch trigger logic to run-id idempotency:
   - Remove SHA-only skip as deployment gate.
   - Gate deploy decisions on `deployed_run_id`.
   - Keep recording SHA for observability.
3. Enforce strict Cloudflare behavior when `CLOUDFLARE_PURGE=true`:
   - Missing env file or required vars => deployment failure.
4. Add per-target nginx refresh toggle (Option B):
   - Support `REFRESH_NGINX=true|false` in target conf.
   - Default to `true` for backward compatibility.
   - Skip nginx refresh step when `false`.
5. Align watch timeout default to 15 minutes in PLAN.md (script + README already at 15).
6. Move to `set -euo pipefail` in `auto-redeploy.sh`.
7. Update docs (`PLAN.md`, `auto-redeploy/README.md`) to reflect final policy.
8. Remove legacy scripts/files listed above.

## Decision Checklist (Final Confirmation)

Confirm each item as `YES` or `NO`:

1. Apply the full change bundle in one PR/change set.
2. Keep nginx refresh as part of deploy flow for now.
3. Remove legacy files immediately (same change set).
4. Keep monitor/soak at 24 hours on staging before production deployment of these behavior changes.

## Post-Change Verification Plan

1. Run shell syntax checks for changed scripts.
2. Dry-run auto-redeploy logic where safe.
3. Validate state transitions for:
   - successful new run
   - failed/cancelled run
   - deployment failure after successful CI
4. Confirm Discord alert behavior for:
   - deployment failure
   - Cloudflare strict-fail case
5. Validate systemd units:
   - `daemon-reload`
   - timer active
   - service respects runtime max ceiling

## Notes

- This file is intentionally decision-oriented so implementation can proceed immediately once approved.
- No runtime changes were applied by creating this file.
