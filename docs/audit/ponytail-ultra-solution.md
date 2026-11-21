# Ponytail audit (ultra): project-boccob, branch claude/determined-lovelace-ugiz1b (HEAD 05d88d9)

What this repo does: This is the data code of an on-prem lakehouse. dlt copies source files byte for byte into a raw bucket and indexes them as Iceberg rows ("schema-on-read": no column names or types are assumed). dbt on Trino builds clean, consolidated and curated tables, with a keystore that hands out integer surrogate keys (stable numeric ids for dimension rows). Dagster runs the jobs, and OPA (the policy engine behind Trino) plus Python tools handle masking, retention and GDPR erasure.
Load I assumed: a mid-size public authority. That means tens of sources, millions of rows a day, 5 years of bookkeeping history, a handful of concurrent pipeline runs, dozens of analysts, and tens of erasure or deregistration requests a night. The code itself is built for one writer at a time (pool `lakehouse_writer` = 1).

Checks run: `make lint` passed (127 columns classified, wheels present for amd64 and arm64). `make test` passed (87 pytest tests, 41/41 OPA tests, Dagster validate). Findings 1 and 7 come from a throwaway Dagster script in the scratchpad (no repo files touched).

## Must fix

1. **A day with no file from one entity skips the whole refresh, and the run still shows green** (`orchestration/assets/ingestion.py:L48,L53-L66`)
   - **What this is:** The landing asset reports one result per entity that delivered files. Its outputs are marked `skippable=True`.
   - **Problem:** In Dagster, a skipped output skips everything downstream. I reproduced it: when `cases` sends no file on a day, `index_<source>` is skipped ("Skipping step index due to skipped dependencies"). When a whole source sends nothing, the dbt step is skipped too. In both cases the run reports success. With tens of sources, or a monthly reference snapshot, dbt, the keystore and the tests almost never run. The demo source sends every entity every day, so no test sees this.
   - **Fix:** Remove `skippable=True` and yield a `MaterializeResult` for every declared entity, with `files: 0` when nothing came. Add one test in `tests/unit/test_orchestration.py` that materializes with an empty delivery and asserts that the downstream step ran.
   - **If we skip it:** Curated data quietly goes stale while every run looks green.

2. **Each erasure request rewrites every table that holds personal data** (`governance/erasure/executor.py:L325-L327`, `governance/iceberg.py:L105-L124`)
   - **What this is:** Each queued request runs its deletes. Then, for every touched table (raw entities, clean, consolidated, fact, dimension, keystore, baseline, about 11), it runs `optimize` with a 1TB threshold, which rewrites almost every data file, then optimize_manifests, expire_snapshots and remove_orphan_files. It also lists every object version under each table and purges the queue's history.
   - **Problem:** The cost per request is a full rewrite of `clean.payments`, which holds 5 years of rows (hundreds of millions at this load), plus the other tables. The retention job queues every person deregistered more than a year ago, so the first run alone can queue thousands. Tens of requests a night already take hours, and they hold the single writer pool, so `daily_refresh` waits.
   - **Fix:** In `process_pending_requests`, run the delete/update statements for all pending requests first. Then call `purge_history` and the noncurrent purge once per touched table. Then verify, write the audit row and dequeue per request. The per-request audit row and the failure handling stay.
   - **If we skip it:** The nightly window overflows on the first deregistration wave, and the refresh and erasure deadlines slip.

3. **Running an erasure from the command line can corrupt tables that are being written** (`governance/erasure/cli.py:L64-L85`, `executor.py:erase_subject`)
   - **What this is:** `lakehouse-erase` without `--submit` runs the erasure immediately. It uses a Trino session that allows `remove_orphan_files` with zero retention.
   - **Problem:** Nothing stops this while Dagster runs a dbt MERGE. Orphan removal deletes the files the MERGE has written but not yet committed. The commit then points at missing files, and the table cannot be read. `lakehouse-migrate` has exactly this guard (`--outside-dagster`, dev-only by default), but the erasure CLI does not. The same rule is applied in one place and not the other.
   - **Fix:** Outside `LAKEHOUSE_ENV=dev`, make `--submit` the default. Refuse immediate execution and `--process-pending` unless `--outside-dagster` is given (copy the check from `governance/migrations/cli.py:L60-L64`). Add the same one-line test that `test_cli_refuses_to_apply_outside_dev_without_confirmation` has.
   - **If we skip it:** A DPO running one urgent erasure at 02:30 can break `clean.payments`.

4. **The small-cell rule counts dimension versions, not people** (`transform/models/curated/borgerservice/dp_payment_summary.sql:L9-L11`)
   - **What this is:** The data product hides cells with fewer than 5 citizens (disclosure control).
   - **Problem:** `count(distinct f.citizen_key)` counts surrogate keys. With SCD2, each version of a person has its own key. A person who changes postal code or e-mail within the month, and gets paid before and after the change, counts twice. So 3 real people can show as 5, and the cell goes to analysts and the open-data export.
   - **Fix:** Count `distinct ci.person_id` (the pseudonymised business key) in both columns. Add one dbt test with a two-version person.
   - **If we skip it:** Small groups of citizens are published, which is a personal data breach.

5. **A payment that arrives before its case keeps a missing case type forever** (`transform/models/clean/borgerportal/payments.sql:L48,L61`, `fact_payment.sql`)
   - **What this is:** `clean.payments` copies the case type from `clean.cases` with a left join (denormalisation) when the payment is first loaded.
   - **Problem:** The model is incremental, so only new raw rows are processed. If the payment comes in delivery N and its case in N+1, `case_type_code` stays NULL. `fact_payment.case_type_key` then stays `-1`, the unknown member, even after the case exists. Late arrival is handled for citizens (inferred members), not for cases.
   - **Fix:** In the incremental filter, also reselect payments whose `case_type_code` is NULL and whose case now exists: `or p.case_id in (select case_id from {{ ref('cases') }})` restricted to `case_type_code is null`. Or join the case type in `fact_payment` instead of freezing it in clean.
   - **If we skip it:** Payments per case type are wrong in the data product, with no test failing.

## Should fix

6. **Re-indexing an old load rolls clean tables back, and the documented pepper rotation cannot work** (`ingestion/cli.py:L28,L45`, `cases.sql`/`payments.sql` merge, `docs/gdpr.md:L89-L92`)
   - **What this is:** `lakehouse-ingest index --load-id X --reindex` rewrites the raw rows of an old load with a new `_loaded_at`.
   - **Problem:** The next dbt run treats them as new. The `cases`/`payments` MERGE then overwrites the current row with the older state, for example a closed case becomes open again. Deduplication only looks inside the batch. The pepper rotation procedure (re-index, then "full-refresh dbt") needs a full refresh, which `guards.sql` refuses outside dev. Without the full refresh, every person appears twice, under the old and the new pseudonym.
   - **Fix:** Refuse `--reindex` outside dev, the same way as full refresh. In the two MERGE models, keep the target row when it is newer (`source_updated_at`). In gdpr.md, state that pepper rotation is not supported yet and needs its own migration.
   - **If we skip it:** One operator command quietly brings back old case states, and a pepper leak has no safe procedure.

7. **One failing source stops the refresh of all the others** (`orchestration/jobs.py:L54-L58`)
   - **What this is:** `daily_refresh` selects every asset: all sources plus the full dbt build.
   - **Problem:** I checked that when one source's landing fails, the dbt step does not run. With tens of sources, one unreachable API holds back every domain's curated data for the day.
   - **Fix:** Schedule `ingest_<source>` per source and the existing `transform` job on its own (for example at 04:00, or by a sensor once the ingests are done). Drop dbt from `daily_refresh`, or drop `daily_refresh`.
   - **If we skip it:** The availability of the whole lakehouse equals that of the worst source.

8. **All work runs one job at a time, and the index mark would lose loads if it didn't** (`orchestration/assets/ingestion.py:L40,L73`, `ingestion/framework/indexing.py:L155-L174`)
   - **What this is:** Landing, indexing, dbt, erasure, retention and maintenance all use pool `lakehouse_writer` with limit 1. Indexing skips every load whose id is at or below the highest id already indexed.
   - **Problem:** Tens of sources land strictly one after another, even though landing only writes new S3 objects. That conflicts with "a handful of concurrent runs". And as soon as two landings overlap (two backfill partitions, or a CLI `make ingest` next to Dagster), a load with a lower id that commits later is never indexed, and nothing reports it.
   - **Fix:** Store the set of indexed load ids in dlt state instead of a maximum (prune the ids whose manifest has expired). Then take `land_<source>` out of the writer pool and keep only `index_` and the jobs that write Iceberg tables in it.
   - **If we skip it:** The nightly window grows with every source, and parallel runs drop data without any error.

9. **Analysts can rebuild the hidden small cells from the fact table** (`governance/policies/lakehouse/config/data.yaml` curated `read`, `dp_payment_summary` row filter)
   - **What this is:** The docs say small cells are "hidden from analysts by an OPA row filter".
   - **Problem:** Analysts also read `curated.borgerservice.fact_payment` and `dim_citizen`, including pseudonym, postal code, birth year and amounts, none of them masked. One `group by` gives them every hidden cell, down to single people.
   - **Fix:** Decide what is intended. Either move data products to their own schema (`curated.products`) and give `analyst` read on that schema only. Or drop the promise from the docs and keep the filter for the open-data export.
   - **If we skip it:** The disclosure control that is documented to the controller does not exist.

10. **Whole native files are held in memory, several times** (`ingestion/framework/spec.py:NativeFile.content`, `indexing.py:L169`, `formats.py:L40-L95`)
    - **What this is:** Landing takes each file as `bytes`. Indexing reads it with `cat_file`, decodes it to one `str`, and builds a full XML DOM tree or the full JSON document.
    - **Problem:** A 1 GB XML or CSV export (one day at millions of rows) needs several GB of memory in the run pod: bytes, plus a 2-bytes-per-character string for Danish text, plus the DOM. The pod is killed for running out of memory, and the load never indexes.
    - **Fix:** In indexing, open the object as a stream. Feed `hashlib.sha256` while parsing, use `iterparse` with `elem.clear()` for XML, and `csv` over `io.TextIOWrapper`. Raise at the end if the checksum differs; dlt then loads nothing. Change landing to upload with `fs.open(..., "wb")` only when a source needs it.
    - **If we skip it:** The first large export fails ingestion.

11. **Every fact run reads the whole payment history, several times** (`transform/macros/keystore/keystore.sql:keystore_register_inferred, keystore_mark_used, keystore_rekey_adopted`, `fact_payment.sql:L33-L36`)
    - **What this is:** The fact's pre-hooks pick candidates from all of `clean.payments`, twice. The post-hooks scan all of `fact_payment`, twice. The `or payment_id in (...)` in the incremental filter stops Trino from filtering on `_loaded_at` first (predicate pushdown).
    - **Problem:** With 5 years of payments these are full scans of billions of rows on every run. They grow forever, while the new data per run stays the same size.
    - **Fix:** Pass the incremental batch to `keystore_register_inferred` (the same `_loaded_at` filter) instead of `ref('payments')`. Write the rekey part as a separate `union` instead of an `or`.
    - **If we skip it:** The dbt build gets slower every month, inside the single-writer window.

12. **`make bundle-push` can publish an old policy under a new version** (`scripts/push-opa-bundle.sh:L19,L37`, `scripts/build-opa-bundle.sh:L16`)
    - **What this is:** The push script builds the bundle only when `dist/opa/bundle.tar.gz` is missing.
    - **Problem:** If you edit `masking.rego` and run `VERSION=0.3.0 make bundle-push`, the 0.2.0 tarball is pushed as 0.3.0. Both scripts also call `sha256sum` directly, although `lib.sh` has `sha256_file` for macOS.
    - **Fix:** Always call `build-opa-bundle.sh` (it takes under a second), and use `sha256_file`.
    - **If we skip it:** Trino can enforce the wrong masking rules under a version that looks correct.

13. **The registry push password stays on the build host** (`scripts/push-opa-bundle.sh:L25-L27`, `scripts/push-image.sh:L32-L34`; still open from round 4, R4-2)
    - **What this is:** `oras login` / `podman login` store the credential in `~/.docker/config.json` or `auth.json`.
    - **Problem:** No logout and no temporary auth file, so the build host keeps a standing push credential for the production registry.
    - **Fix:** In `registry_trust`, set `REGISTRY_AUTH_FILE`/`--registry-config` to a file in the temp dir, which the existing EXIT trap removes.
    - **If we skip it:** Anyone with that account on the host can push images.

14. **The erasure dry run is a second copy of the erasure plan** (`governance/erasure/plan.py:L287-L345` vs `L140-L284`, `executor.py:L401-L425`)
    - **What this is:** `build_preview` writes its own SQL per table kind (raw, anonymise, delete, keystore), next to `build_plan`.
    - **Problem:** The two must change together. The preview already ignores `scope='deregistration'`: it reports payments as "delete" when they will in fact be kept anonymised.
    - **Fix:** Build both from one per-table function that returns the target and the subject column. The plan wraps it with the queue subquery and the preview with the 2-character prefix.
    - **If we skip it:** The DPO's preview and the real erasure drift apart over time.

15. **An unused second way to grant groups, including `pii-reader`** (`governance/policies/trino/main.rego:L28`, `data.yaml: principals`, `policy_test.rego:L334-L339`)
    - **What this is:** Groups can also come from an OPA data overlay. The contract says it "stays empty on the platform".
    - **Problem:** Unused, but anyone who can write OPA data can give any user `pii-reader` or `lakehouse-service` without Keycloak, outside the access review.
    - **Fix:** Delete the rule, the `principals: {}` key, the test and the contract paragraph.
    - **If we skip it:** A hidden path around the group provider stays in the security policy.

16. **Compatibility code for releases that never ran in production** (`governance/migrations/runner.py:L77,L164,L213`, `governance/erasure/executor.py:L471`, `governance/classification/manifest.py:_meta` top-level meta)
    - **What this is:** It accepts old raw-file migration checksums ("before 0.2.1"), queue rows without `scope` ("older release"), and top-level dbt meta, although `dbt_project.yml` requires dbt >=1.10.
    - **Problem:** Production has never run (round 4), and dev can be migrated once. The code has to be read, tested and kept forever, and the `requested_by = 'retention-policy'` guess decides how much gets erased.
    - **Fix:** Re-record the dev checksums once, then delete the legacy branches and their tests.
    - **If we skip it:** About 20 lines of dead logic stay on the erasure and migration paths.

## Nice to have

17. **The calendar runs only from 2020 to 2035** (`transform/models/curated/borgerservice/dim_date.sql:L13`)
    - **What this is:** `dim_date` is a fixed date sequence.
    - **Problem:** A first load of payment history from 2019, or any payment from 2036 on, fails the `payment_date_key` relationship test, and the build stops.
    - **Fix:** Derive the range from `min/max(payment_date)` with a margin, or widen it to 1990-2099.
    - **If we skip it:** The build breaks on old history, or in 2036.

18. **The retention dry run writes** (`governance/retention/runner.py:L143`)
    - **What this is:** `queue_deregistered` calls `ensure_queue()` before it checks `dry_run`.
    - **Problem:** `make retention-dry-run` creates or changes the queue table, so a read-only principal cannot run it.
    - **Fix:** Move `ensure_queue()` into the non-dry-run branch.
    - **If we skip it:** A "report only" command needs write rights.

Left out: about 4 smaller items (dbt profile default target is http without auth, while Python defaults to https; `jq` is used without `need jq`; landing objects `_dlt_*` are never cleaned; `SCAN_STRICT` is off by default).

Verdict: Fix 1 first (a one-line cause of silently stale data), then 2 and 3 (erasure cost and erasure data loss), then 4 (privacy).
Lean: -80 lines, -0 dependencies possible.
Not checked: The integration test was not run (forbidden), so findings 1 and 7 were confirmed with a minimal Dagster script, not the real job. Not read in depth: `tests/integration/test_e2e.py`, `generator.py`, `install-tools.sh`, `check-wheels.py`, `generic_tests.sql`, `harness.sh` after line 60, `uv.lock`, the IaC repository. No image build, no macOS run, no load test. The Trino behaviour of `optimize` with a 1TB threshold is from its docs, not measured.

## Ultra: pushback on scope

What the stated need does not justify, each with the smallest alternative:

- **Object-store forensic scan after erasure** (`governance/erasure/storage_scan.py`, the `off/scoped/full` modes, `deferred_hits`, Parquet and Avro decoding). The need is "scripted erasure", and SQL verification plus the version purge already prove it. Smallest alternative: keep the scan as a helper of the integration test only. In production keep SQL verification. If the DPO wants more, keep `scoped` and delete `full` and the deferred logic.
- **Keystore retry with a CPU-burning backoff** (`keystore_allocate` loop, `keystore_backoff`, the three-process concurrency test). The writer pool already guarantees one writer, and the retry only covers operator mistakes. Smallest alternative: keep the collision check, fail the model on a collision, and delete the retry and the backoff.
- **Migration advisory lock with TTL, `--outside-dagster`, legacy checksums.** The Dagster `migrate` job already runs in the writer pool. Smallest alternative: the CLI applies migrations in dev only, and outside dev it is the Dagster job. Delete the lock table and its tests.
- **Digest staging table `raw.governance.erasure_digests`.** It keeps an HMAC digest out of WORM query text, but the same digest is stored permanently in `curated.audit.erasure_log` anyway, and the platform audit sink already redacts 64-hex literals. Smallest alternative: insert the digest directly and delete the staging table and its cleanup.
- **Multi-platform manifest lists, emulation checks and per-arch SBOMs** (`build-image.sh`, about half of its 125 lines). "Runs on x64 and Apple Silicon" is met by the native single-platform build, which is already the default. Smallest alternative: build natively, and add a multi-arch publish only when a cluster actually has arm64 nodes.
- **Two signing paths** (`COSIGN_KEY` in `push-image.sh`, and the IaC `make sign` with OpenBao transit). Smallest alternative: keep the IaC as the only signer and delete the cosign branch.
- **`consolidated.party.person` as a stored incremental copy, while there is one source.** It is a column rename of `clean.citizens`, and it adds another full copy of personal data to erase, retain and purge. Smallest alternative: make it a view until a second source exists, so the optional layer stays in the design at no data cost.
- **A dry run that matches by 2-character key prefix** (finding 14). Smallest alternative: a dry run that lists tables and actions from `build_plan`, with real counts reported by the queued job.
- **`SCHEDULE_TIMEZONE`, which differs from the partition timezone hard-coded to Europe/Copenhagen.** It is one setting in two places, and only one of them is configurable. Smallest alternative: delete `SCHEDULE_TIMEZONE`.
- **Audit-history references in docs and code** ("audit N-3", "R3-1", "release 0.2"). Docs should describe the current system. Smallest alternative: keep audit IDs in commit messages and the audit reports.
- **The OPA `principals` overlay** (finding 15). Delete it.
