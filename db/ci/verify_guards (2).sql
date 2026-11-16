-- db/ci/verify_guards.sql : run after baseline on a fresh database.
-- Exits non-zero via ON_ERROR_STOP when any guard fails.
\set ON_ERROR_STOP on

DO $$
BEGIN
  -- expected table count (34 contract tables + script_version = 35)
  IF (SELECT count(*) FROM information_schema.tables
      WHERE table_schema='public' AND table_type='BASE TABLE') <> 35 THEN
    RAISE EXCEPTION 'expected 35 base tables';
  END IF;
  -- RLS enabled+forced on all tenant tables
  IF EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
             WHERE n.nspname='public' AND c.relkind='r'
               AND NOT c.relrowsecurity AND c.relname IN (
                 'test_case','task','run','attempt','evidence','timing_sample',
                 'verdict_record','resource_lock','step_registry','step_impl_version',
                 'step_sample','symbol_def','symbol_version','symbol_alias',
                 'composition','composition_version','composition_review',
                 'case_composition_binding','task_case','step_execution',
                 'judge_review','run_resource','idempotency_record','project','app_user')) THEN
    RAISE EXCEPTION 'RLS not enabled on all tenant tables';
  END IF;
END $$;
\echo guards structure OK
