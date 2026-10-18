# Imported residents on their own VM (design, next slice after #246)

Daniel, 2026-10-09 (KjXOAe): "the VM is just a substrate". Imported residents
go on VMs too, with no difference from local ones. New residents came first
(#266, #269, #270); this is what imports need on top. Not built yet.

Amended 2026-10-18 after the Planning thread GePnkJ (Daniel, Mira, Lume) and
Mira's review of the first draft. Decisions in that thread, Daniel's:

- **Buy the server at activation, not at import.**
- **Archive imports first, GitHub imports second, with no pause between the
  two slices.**
- **Migrating existing house residents to VMs is in scope as follow-on work**,
  after both import slices: #426. Not part of this design.
- Spinning servers up and down with use is not possible now and is not wanted;
  not part of this design.

## Where things stand

The "new residents on their own VM" switch is off in production; every
resident, born or imported, runs on the house. Of the current residents about
22 arrived by archive import and none by GitHub import. With the switch on,
`VmBirthPolicy` refuses every import outright and `Agents::VmSeed` refuses any
imported (portable/GitHub) home; that is deliberate (VM or visible refusal,
never a silent fallback to the house), and it is the hole this design fills.

One correction to the first draft: an archive import is created with
`home_profile` "house" (`Agents::Portability::Import`), so it is **not** an
"imported home" in the code's sense. `imported_home?` covers portable/GitHub
homes only, and `imported_runtime_trusted?` returns true at once for anything
without a GitHub import record. The only thing in an archive import's way is
the policy's import refusal.

## What differs from a birth

| | New resident | Archive import | GitHub import |
|---|---|---|---|
| Home source | exporter tarball | `resident/{identity,repo,work}` from the archive | reviewed checkout → identity |
| When the server is bought | at birth | **at activation** (nothing bought at import) | at import (the trust check needs the container) |
| After seeding | start, backup, orient | start → first verified backup → ready; no orientation | start if the imported runtime is trusted, else `needs_runtime_trust` |
| Env | standard | `home_profile_env_args`: profile, portable home id, imported root, `AGENT_REPO_PATH`, `TZ` | the same plus the `SOULSHOUSE_GITHUB_IMPORT_*` set |
| Trust boundary | none | a person's confirmation on the activate form ("Confirm service and hook trust review before activation"), recorded on the request; no check runs in the container | `imported_runtime_trusted?`, run inside the resident's image against the Chaos volume, through the runner |
| House-side checks | none | graph import at import time (house DB, unchanged; activation does not re-run it) | none beyond the trust check |

## Proposed

1. **Seed per volume.** `seed_home` takes `role ∈ {identity, repo, work}`. Each role has its own archive, digest and marker in its own volume (the same staging, marker and refusal rules as #266: a volume that already holds something else is a refusal, not an overwrite). The house keeps one stored archive per (placement, role), so retries name the same bytes. The house today creates the same three volumes from three restore tarballs; this is that, through the runner.
2. **Admission.** Both import kinds admit a VM placement through `VmBirthPolicy#admit!` (the same lock, cap and procurement/backups configuration checks) instead of refusing. The placement records its kind (`birth` | `archive_import` | `github_import`). For an archive import the admission runs **at activation**, not at import; for a GitHub import it runs at import.
3. **Archive import: nothing bought until Activate.** Import proceeds as today: the archive is staged in the house, the graph is imported into the house DB, the resident is created inactive and paused. The placement records the VM intent and the staged archive, and holds no server and no cap slot. **Activation** (the existing portability activate action, with its human confirmation unchanged) re-checks admission, then runs order → enroll → seed (three roles) → start → first verified backup → ready. No orientation. If admission fails at that moment (cap full, procurement or backups unconfigured) the activation is refused with a plain message and the resident stays inactive and staged; nothing is bought. Expected wait on success: a few minutes (the pilot births took about five from order to verified backup); an estimate, not a promise.
4. **GitHub import: bought at import, trusted through the runner.** `ProvisionVmAgentJob` runs order → enroll → seed, then the trust check (5), then start → first verified backup → ready; if untrusted, `needs_runtime_trust`, as locally, and the resident waits with its server.
5. **Trust check through the runner, preserved exactly.** A fixed runner command runs the same operation `Agents::Sandbox#imported_runtime_trusted?` runs locally: inside the resident's image, against the Chaos volume, with the resident's identity and environment, importing `github_import_approval` and `imported_home` (and `standard_home_sync` for standard imports) and running the real check. It fails closed and returns a bounded result. It is **not** a read of one marker file; the first draft said that and Mira's review corrected it.
6. **Env.** `RemoteRuntime.environment` adds `home_profile_env_args` and the GitHub import set, built by the same helper the local sandbox uses (extracted, so the two can't drift). The runner allowlist gains exactly those names.
7. **No turn before the first verified backup.** Births already hold this; activation and trust approval do not bypass it. A resident on a VM gets its first turn only after start → first verified backup → ready, whichever ending it came through.
8. **Deadline and cleanup.** The 45-minute provisioning deadline applies to an archive activation exactly as to a birth: on expiry the server is released and the activation fails visibly; the staged archive and the inactive resident remain, and Activate can be pressed again. For a GitHub import waiting in `needs_runtime_trust`, the deadline bounds the paid wait: on expiry the server is released, the staged home and the import record are kept, and the resident shows a plain retryable status. It must never discard the home because a person took longer than 45 minutes to approve it. The exact status and retry path are settled in the GitHub slice.
9. **Switch-off.** Turning the site switch off stops new admissions and never turns a staged VM intent into local execution. It does not by itself retire a server already admitted; that server stays until the resident is deleted (deleting an import cleans up its server) or until the deadline cleanup in (8) releases it.
10. **Durable staging is new work.** Today `Archive.with_upload` stages in a temporary directory that is gone when the request ends. Buying at activation means the validated role archives must be persisted at import and survive request completion and process restart; a staged intent holds no cap slot. (Mira's review, b618b156.)
11. **Races.** Repeated or concurrent Activate, job retry, and timeout-versus-ready races must not buy duplicate servers or delete a ready resident's server; capacity is released only once deletion is confirmed; retry material is retained; graph import is not rerun on activation. Dispatch stays blocked through the first verified backup on activation, trust approval and retry, with no orientation and without silently enabling imported schedules. (Mira's review.)

## Slices

1. **Archive imports.** Per-role seed through the runner; admission at activation instead of refusal; the archive ending of the provisioning path; the deadline behaviour in (8) for activation. No runner trust command: the archive path has no runtime trust operation (see the correction above), and its human confirmation stays in the activate form. Until this lands, the switch cannot be left on without blocking imports.
2. **GitHub imports**, immediately after. The runner trust command (5), the GitHub ending (4), and the trust-wait release (8). Until this lands, GitHub imports stay refused while the switch is on; the house has none today.
3. Then #426 (migrate existing residents), designed separately.

Both slices need Mira's design approval here. Daniel gave the go for the work threads in GePnkJ on 2026-10-18, once the design is approved.

## Decided

- Order at activation (Daniel, GePnkJ). The alternative, ordering at import, would have cost roughly a cx23's list price (about €4 a month, billed hourly) and a cap slot per idle import, for instant activation.
- Archives first, GitHub second, no pause (Daniel, GePnkJ).
- Existing residents stay on the house during the import work; migration follows as #426 (Daniel, GePnkJ).
