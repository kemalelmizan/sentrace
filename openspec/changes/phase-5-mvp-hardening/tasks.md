# Tasks

## 1. Batch Event & Orphan Issue Retention

- [x] 1.1 Add `retention_batch_size` and `internal_authenticator` to `Sentrace::Configuration`, implement `Sentrace::Retention::Cleaner` (`lib/sentrace/retention/cleaner.rb`), `Sentrace::RetentionCleanupJob` (`app/jobs/sentrace/retention_cleanup_job.rb`), and Rake task `sentrace:retention:cleanup` (`lib/tasks/sentrace_retention.rake`), and verify unit and job/rake specs pass

## 2. PostgreSQL Storage Observability & Internal Admin API

- [x] 2.1 Implement `Sentrace::StorageStats` (`lib/sentrace/storage_stats.rb`) and `sentrace:stats` Rake task, mount `/sentrace/internal` routes (`projects`, `issues`, `events`, `stats`) under `app/controllers/sentrace/internal/`, and verify storage stats and internal API request specs pass

## 3. Repeatable Storage Benchmark, Security Verification & Release Readiness

- [ ] 3.1 Implement `Sentrace::Benchmark::StorageRunner` (`lib/sentrace/benchmark/storage_runner.rb`) and `sentrace:benchmark:storage` Rake task (`lib/tasks/sentrace_benchmark.rake`), add `SPEC.md` §11/§13 performance and security invariant specs (`spec/lib/sentrace/benchmark/storage_runner_spec.rb`, `spec/security/security_invariants_spec.rb`), complete `README.md` documentation and `SPEC.md` §15 acceptance checklist, and verify full RSpec, RuboCop, and benchmark execution

## Workflow follow-up

- Run `openspec validate --all --strict --no-interactive`, verify full RSpec + RuboCop + benchmark suites, and archive `phase-5-mvp-hardening`.
