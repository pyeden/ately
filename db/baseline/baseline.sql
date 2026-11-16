-- ATEly baseline schema (PostgreSQL 16)
-- 19 base tables + 15 new tables = 34. Fresh-deployment baseline only.
-- Fixes over OpenATE PRD v1.2.1 (docs/adr/ADR-001..005):
--   FIX-1 parents UNIQUE(project_id,id); children composite FKs.
--   FIX-2 TimescaleDB optional, guarded by shared_preload_libraries check.
--   FIX-4 judge_review append-only; one resolve per attempt (part-unique).
--   FIX-5 freeze requires approve reviews; dual approval for ai/mixed origin.
-- Run: psql -v ON_ERROR_STOP=1 -f baseline.sql

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE FUNCTION gen_id() RETURNS char(26) LANGUAGE plpgsql AS $$
DECLARE
  ts bigint; rnd bytea; alpha text := '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  out text; i int; v int;
BEGIN
  ts := (extract(epoch from clock_timestamp())*1000)::bigint;
  FOR i IN REVERSE 0..7 LOOP out := out || substr(alpha, ((ts >> (i*5)) & 31)::int + 1, 1); END LOOP;
  rnd := gen_random_bytes(10);
  FOR i IN 0..15 LOOP
    v := get_byte(rnd, i/2); IF i%2=0 THEN v := v >> 4; ELSE v := v & 15; END IF;
    out := out || substr(alpha, (v & 31) + 1, 1);
  END LOOP;
  RETURN out;
END $$;

CREATE FUNCTION touch_updated_at() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at := now(); RETURN NEW; END $$;

-- ================= A. base domain =================
CREATE TABLE project (
  id char(26) PRIMARY KEY,
  tenant_id varchar(64) NOT NULL DEFAULT 'default',
  name varchar(256) NOT NULL,
  description text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_project_tenant_name UNIQUE (tenant_id, name)
);
CREATE TRIGGER trg_project_touch BEFORE UPDATE ON project FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

CREATE TABLE app_user (
  id char(26) PRIMARY KEY,
  tenant_id varchar(64) NOT NULL DEFAULT 'default',
  display_name varchar(256) NOT NULL,
  email varchar(320),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE project_member (
  id char(26) PRIMARY KEY,
  tenant_id varchar(64) NOT NULL DEFAULT 'default',
  project_id char(26) NOT NULL REFERENCES project(id),
  user_id char(26) NOT NULL REFERENCES app_user(id),
  role varchar(16) NOT NULL DEFAULT 'member',
  CONSTRAINT uq_project_member UNIQUE (project_id, user_id),
  CONSTRAINT ck_member_role CHECK (role IN ('owner','maintainer','member','viewer'))
);

CREATE TABLE test_case (
  id char(26) PRIMARY KEY,
  tenant_id varchar(64) NOT NULL DEFAULT 'default',
  project_id char(26) NOT NULL,
  code varchar(64) NOT NULL,
  title varchar(256) NOT NULL,
  precondition text,
  steps jsonb NOT NULL,
  expected text,
  priority varchar(8) NOT NULL DEFAULT 'P2',
  tags jsonb NOT NULL DEFAULT '[]',
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT fk_case_project FOREIGN KEY (project_id) REFERENCES project(id),
  CONSTRAINT uq_case_code UNIQUE (project_id, code),
  CONSTRAINT ck_case_priority CHECK (priority IN ('P0','P1','P2','P3'))
);
CREATE TRIGGER trg_case_touch BEFORE UPDATE ON test_case FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

CREATE TABLE script (
  id char(26) PRIMARY KEY,
  tenant_id varchar(64) NOT NULL DEFAULT 'default',
  project_id char(26) NOT NULL,
  name varchar(256) NOT NULL,
  language varchar(32) NOT NULL DEFAULT 'python',
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT fk_script_project FOREIGN KEY (project_id) REFERENCES project(id),
  CONSTRAINT uq_script_pid_name UNIQUE (project_id, name)
);
-- FIX-1: parents referenced with (project_id,id) by children
CREATE UNIQUE INDEX uq_script_project_id ON script(project_id, id);
CREATE UNIQUE INDEX uq_case_project_id ON test_case(project_id, id);

CREATE TABLE script_version (
  id char(26) PRIMARY KEY,
  tenant_id varchar(64) NOT NULL DEFAULT 'default',
  project_id char(26) NOT NULL,
  script_id char(26) NOT NULL,
  version integer NOT NULL,
  content text NOT NULL,
  content_hash char(64) NOT NULL,
  created_by char(26) REFERENCES app_user(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT fk_sv_script FOREIGN KEY (project_id, script_id) REFERENCES script(project_id, id),
  CONSTRAINT uq_script_version UNIQUE (script_id, version)
);

CREATE TABLE case_script_binding (
  id char(26) PRIMARY KEY,
  tenant_id varchar(64) NOT NULL DEFAULT 'default',
  project_id char(26) NOT NULL,
  case_id char(26) NOT NULL,
  script_id char(26) NOT NULL,
  script_version integer NOT NULL,
  bound_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT fk_csb_case FOREIGN KEY (project_id, case_id) REFERENCES test_case(project_id, id),
  CONSTRAINT fk_csb_script FOREIGN KEY (project_id, script_id) REFERENCES script(project_id, id),
  CONSTRAINT uq_case_script UNIQUE (case_id)
);

CREATE TABLE parameter_set (
  id char(26) PRIMARY KEY,
  tenant_id varchar(64) NOT NULL DEFAULT 'default',
  project_id char(26) NOT NULL REFERENCES project(id),
  name varchar(256) NOT NULL,
  data jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_param_set UNIQUE (project_id, name)
);

CREATE TABLE scenario (
  id char(26) PRIMARY KEY,
  tenant_id varchar(64) NOT NULL DEFAULT 'default',
  project_id char(26) NOT NULL REFERENCES project(id),
  name varchar(256) NOT NULL,
  data jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_scenario UNIQUE (project_id, name)
);

CREATE TABLE device (
  id char(26) PRIMARY KEY,
  tenant_id varchar(64) NOT NULL DEFAULT 'default',
  project_id char(26) NOT NULL REFERENCES project(id),
  code varchar(64) NOT NULL,
  driver varchar(64) NOT NULL DEFAULT 'sim',
  meta jsonb NOT NULL DEFAULT '{}',
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_device_code UNIQUE (project_id, code)
);
CREATE UNIQUE INDEX uq_device_project_id ON device(project_id, id);

CREATE TABLE task (
  id char(26) PRIMARY KEY,
  tenant_id varchar(64) NOT NULL DEFAULT 'default',
  project_id char(26) NOT NULL REFERENCES project(id),
  name varchar(256) NOT NULL,
  status varchar(16) NOT NULL DEFAULT 'DRAFT',
  created_by char(26) REFERENCES app_user(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_task_status CHECK (status IN ('DRAFT','QUEUED','RUNNING','FINISHED','CANCELLED'))
);
CREATE TRIGGER trg_task_touch BEFORE UPDATE ON task FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE UNIQUE INDEX uq_task_project_id ON task(project_id, id);

CREATE TABLE run (
  id char(26) PRIMARY KEY,
  tenant_id varchar(64) NOT NULL DEFAULT 'default',
  project_id char(26) NOT NULL,
  task_id char(26) NOT NULL,
  status varchar(16) NOT NULL DEFAULT 'QUEUED',
  device_ids jsonb NOT NULL DEFAULT '[]',
  idempotency_key varchar(128),
  cancel_requested_at timestamptz,
  cancel_mode varchar(16),
  created_at timestamptz NOT NULL DEFAULT now(),
  finished_at timestamptz,
  CONSTRAINT fk_run_task FOREIGN KEY (project_id, task_id) REFERENCES task(project_id, id),
  CONSTRAINT ck_run_status CHECK (status IN (
    'QUEUED','DISPATCHING','RUNNING','PAUSED','CANCELLING',
    'SUCCEEDED','FAILED','CANCELLED','ABORTED')),
  CONSTRAINT ck_run_cancel_mode CHECK (cancel_mode IS NULL OR cancel_mode IN ('GRACEFUL','FORCE'))
);
CREATE UNIQUE INDEX uq_run_project_id ON run(project_id, id);

CREATE TABLE attempt (
  id char(26) PRIMARY KEY,
  tenant_id varchar(64) NOT NULL DEFAULT 'default',
  project_id char(26) NOT NULL,
  run_id char(26) NOT NULL,
  task_case_id char(26),
  case_id char(26),
  device_id char(26),
  status varchar(16) NOT NULL DEFAULT 'PENDING',
  verdict varchar(16) NOT NULL DEFAULT 'NOT_TESTED',
  execution_kind varchar(16) NOT NULL DEFAULT 'SCRIPT',
  composition_version_id char(26),
  judge_state varchar(16) NOT NULL DEFAULT 'NONE',
  judge_reason text,
  started_at timestamptz,
  finished_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_attempt_status CHECK (status IN (
    'PENDING','RUNNING','PASSED','FAILED','SKIPPED','ERROR','NEED_HUMAN','CANCELLED')),
  CONSTRAINT ck_attempt_verdict CHECK (verdict IN ('PASS','FAIL','INCONCLUSIVE','NOT_TESTED','NOT_APPLICABLE')),
  CONSTRAINT ck_attempt_execution_kind CHECK (execution_kind IN ('SCRIPT','COMPOSITION')),
  CONSTRAINT ck_attempt_judge_state CHECK (judge_state IN ('NONE','NEED_HUMAN','RESOLVED')),
  CONSTRAINT ck_attempt_human_pair CHECK (
    (status = 'NEED_HUMAN' AND verdict = 'NOT_TESTED' AND judge_state = 'NEED_HUMAN')
    OR (status <> 'NEED_HUMAN' AND judge_state <> 'NEED_HUMAN'))
);
CREATE INDEX ix_attempt_run ON attempt(run_id);
CREATE UNIQUE INDEX uq_attempt_project_id ON attempt(project_id, id);

CREATE TABLE evidence (
  id char(26) PRIMARY KEY,
  tenant_id varchar(64) NOT NULL DEFAULT 'default',
  attempt_id char(26) NOT NULL,
  project_id char(26) NOT NULL,
  evidence_type varchar(16) NOT NULL,
  content text,
  content_hash char(64),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT fk_evidence_attempt FOREIGN KEY (project_id, attempt_id) REFERENCES attempt(project_id, id),
  CONSTRAINT ck_evidence_type CHECK (evidence_type IN ('RESULT','ATTACHMENT','TIMING','IDENTITY')),
  CONSTRAINT ck_evidence_body CHECK (
    (evidence_type = 'ATTACHMENT' AND content_hash IS NOT NULL AND content IS NULL)
    OR (evidence_type <> 'ATTACHMENT' AND (content IS NOT NULL OR content_hash IS NOT NULL)))
);

CREATE TABLE timing_sample (
  ts timestamptz NOT NULL,
  id char(26) NOT NULL DEFAULT gen_id(),
  tenant_id varchar(64) NOT NULL DEFAULT 'default',
  project_id char(26) NOT NULL,
  attempt_id char(26) NOT NULL,
  symbol_version_id char(26),
  raw_value double precision,
  canonical_unit varchar(32),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_timing_project_ts ON timing_sample(project_id, ts DESC);
CREATE UNIQUE INDEX uq_timing_project_id ON timing_sample(project_id, id);

CREATE TABLE verdict_record (
  id char(26) PRIMARY KEY,
  tenant_id varchar(64) NOT NULL DEFAULT 'default',
  attempt_id char(26) NOT NULL,
  project_id char(26) NOT NULL,
  verdict varchar(16) NOT NULL,
  source varchar(16) NOT NULL DEFAULT 'auto',
  reason text,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT fk_vr_attempt FOREIGN KEY (project_id, attempt_id) REFERENCES attempt(project_id, id),
  CONSTRAINT ck_judge_verdict CHECK (verdict IN ('PASS','FAIL','INCONCLUSIVE','NEED_HUMAN','CONTINUE','NOT_APPLICABLE'))
);

CREATE TABLE resource_lock (
  id char(26) PRIMARY KEY,
  tenant_id varchar(64) NOT NULL DEFAULT 'default',
  project_id char(26) NOT NULL REFERENCES project(id),
  device_id char(26) NOT NULL,
  run_id char(26),
  batch_id char(26),
  acquired_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  released_at timestamptz,
  release_reason varchar(24),
  CONSTRAINT fk_lock_device FOREIGN KEY (project_id, device_id) REFERENCES device(project_id, id),
  CONSTRAINT ck_lock_release_reason CHECK (release_reason IS NULL OR release_reason IN (
    'NORMAL','CANCELLED','EXPIRED_SWEEP','FORCE_RELEASED'))
);
CREATE UNIQUE INDEX uq_lock_active ON resource_lock(project_id, device_id) WHERE released_at IS NULL;
CREATE INDEX ix_lock_expiry ON resource_lock(expires_at) WHERE released_at IS NULL;

CREATE TABLE audit_log (
  id char(26) PRIMARY KEY DEFAULT gen_id(),
  tenant_id varchar(64) NOT NULL DEFAULT 'default',
  project_id char(26),
  actor char(26),
  action varchar(64) NOT NULL,
  detail jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE blob_ref (
  id char(26) PRIMARY KEY DEFAULT gen_id(),
  tenant_id varchar(64) NOT NULL DEFAULT 'default',
  content_hash char(64) NOT NULL,
  size_bytes bigint NOT NULL,
  storage_key text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_blob_hash UNIQUE (content_hash)
);

CREATE TABLE event_outbox (
  id char(26) PRIMARY KEY DEFAULT gen_id(),
  tenant_id varchar(64) NOT NULL DEFAULT 'default',
  project_id char(26),
  topic varchar(128) NOT NULL,
  payload jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  published_at timestamptz
);
CREATE INDEX ix_outbox_pending ON event_outbox(created_at) WHERE published_at IS NULL;

-- ================= B. spec domain (new tables) =================
CREATE TABLE step_registry (
  id char(26) PRIMARY KEY,
  tenant_id varchar(64) NOT NULL DEFAULT 'default',
  project_id char(26) NOT NULL REFERENCES project(id),
  step_key varchar(128) NOT NULL,
  name varchar(256) NOT NULL,
  domain varchar(64) NOT NULL,
  maturity varchar(16) NOT NULL DEFAULT 'experimental',
  semantic_freeze varchar(16) NOT NULL DEFAULT 'evolving',
  status varchar(16) NOT NULL DEFAULT 'active',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_step_key UNIQUE (tenant_id, project_id, step_key),
  CONSTRAINT ck_step_maturity CHECK (maturity IN ('experimental','beta','stable','frozen','deprecated')),
  CONSTRAINT ck_step_semantic_freeze CHECK (semantic_freeze IN ('evolving','frozen')),
  CONSTRAINT ck_step_status CHECK (status IN ('active','deprecated'))
);
CREATE INDEX ix_step_domain ON step_registry(tenant_id, project_id, domain, status);
CREATE UNIQUE INDEX uq_step_project_id ON step_registry(project_id, id);

CREATE TABLE step_impl_version (
  id char(26) PRIMARY KEY,
  tenant_id varchar(64) NOT NULL DEFAULT 'default',
  project_id char(26) NOT NULL,
  step_id char(26) NOT NULL,
  impl_version varchar(32) NOT NULL,
  content_hash char(64) NOT NULL,
  param_schema jsonb NOT NULL,
  impl_uri text NOT NULL,
  compat_note text,
  created_at timestamptz NOT NULL DEFAULT now(),
  deprecated_at timestamptz,
  CONSTRAINT fk_siv_step FOREIGN KEY (project_id, step_id) REFERENCES step_registry(project_id, id),
  CONSTRAINT uq_step_impl UNIQUE (step_id, impl_version)
);
CREATE INDEX ix_step_impl_hash ON step_impl_version(content_hash);
CREATE UNIQUE INDEX uq_siv_project_id ON step_impl_version(project_id, id);

CREATE TABLE step_sample (
  id char(26) PRIMARY KEY,
  tenant_id varchar(64) NOT NULL DEFAULT 'default',
  project_id char(26) NOT NULL,
  step_impl_version_id char(26) NOT NULL,
  direction varchar(16) NOT NULL,
  seq integer NOT NULL,
  payload jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT fk_sample_siv FOREIGN KEY (project_id, step_impl_version_id) REFERENCES step_impl_version(project_id, id),
  CONSTRAINT ck_sample_direction CHECK (direction IN ('stimulus','expected')),
  CONSTRAINT uq_sample_seq UNIQUE (step_impl_version_id, direction, seq)
);

CREATE TABLE symbol_def (
  id char(26) PRIMARY KEY,
  tenant_id varchar(64) NOT NULL DEFAULT 'default',
  project_id char(26) NOT NULL REFERENCES project(id),
  symbol_key varchar(128) NOT NULL,
  display_name varchar(256) NOT NULL,
  status varchar(16) NOT NULL DEFAULT 'active',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_symbol_key UNIQUE (tenant_id, project_id, symbol_key),
  CONSTRAINT ck_symbol_status CHECK (status IN ('active','deprecated'))
);
CREATE UNIQUE INDEX uq_symbol_project_id ON symbol_def(project_id, id);

CREATE TABLE symbol_version (
  id char(26) PRIMARY KEY,
  tenant_id varchar(64) NOT NULL DEFAULT 'default',
  project_id char(26) NOT NULL,
  symbol_id char(26) NOT NULL,
  version integer NOT NULL,
  category varchar(32) NOT NULL,
  canonical_unit varchar(32),
  min_value numeric(28,9),
  max_value numeric(28,9),
  resolution numeric(28,9),
  enum_map jsonb,
  data_type varchar(16) NOT NULL DEFAULT 'float',
  maturity varchar(16) NOT NULL DEFAULT 'experimental',
  source_doc text,
  content_hash char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT fk_symv_symbol FOREIGN KEY (project_id, symbol_id) REFERENCES symbol_def(project_id, id),
  CONSTRAINT uq_symbol_version UNIQUE (symbol_id, version),
  CONSTRAINT ck_symbol_category CHECK (category IN ('signal','parameter','enum','did','threshold')),
  CONSTRAINT ck_symbol_range CHECK (min_value IS NULL OR max_value IS NULL OR min_value <= max_value),
  CONSTRAINT ck_symbol_data_type CHECK (data_type IN ('float','int','bool','enum','string')),
  CONSTRAINT ck_symbol_version_maturity CHECK (maturity IN ('experimental','beta','stable','frozen','deprecated'))
);
CREATE UNIQUE INDEX uq_symv_project_id ON symbol_version(project_id, id);

CREATE TABLE symbol_alias (
  id char(26) PRIMARY KEY,
  tenant_id varchar(64) NOT NULL DEFAULT 'default',
  project_id char(26) NOT NULL REFERENCES project(id),
  symbol_id char(26) NOT NULL,
  alias_text varchar(256) NOT NULL,
  alias_norm varchar(256) NOT NULL,
  lang varchar(8) NOT NULL DEFAULT 'zh',
  weight numeric(4,2) NOT NULL DEFAULT 1.0,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT fk_alias_symbol FOREIGN KEY (project_id, symbol_id) REFERENCES symbol_def(project_id, id),
  CONSTRAINT uq_symbol_alias UNIQUE (tenant_id, project_id, alias_norm, symbol_id)
);
CREATE INDEX ix_symbol_alias ON symbol_alias(tenant_id, project_id, alias_norm);

CREATE TABLE composition (
  id char(26) PRIMARY KEY,
  tenant_id varchar(64) NOT NULL DEFAULT 'default',
  project_id char(26) NOT NULL REFERENCES project(id),
  name varchar(256) NOT NULL,
  created_by char(26) REFERENCES app_user(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER trg_composition_touch BEFORE UPDATE ON composition FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE UNIQUE INDEX uq_composition_project_id ON composition(project_id, id);

CREATE TABLE composition_version (
  id char(26) PRIMARY KEY,
  tenant_id varchar(64) NOT NULL DEFAULT 'default',
  project_id char(26) NOT NULL,
  composition_id char(26) NOT NULL,
  version integer NOT NULL,
  status varchar(16) NOT NULL DEFAULT 'draft',
  origin varchar(16) NOT NULL DEFAULT 'human',
  steps jsonb NOT NULL,
  semantic_hash char(64),
  based_on_version_id char(26),
  created_by char(26) NOT NULL REFERENCES app_user(id),
  reviewed_by char(26) REFERENCES app_user(id),
  reviewed_at timestamptz,
  ai_confidence numeric(4,3),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT fk_cv_composition FOREIGN KEY (project_id, composition_id) REFERENCES composition(project_id, id),
  CONSTRAINT uq_composition_version UNIQUE (composition_id, version),
  CONSTRAINT ck_composition_status CHECK (status IN ('draft','review','frozen','deprecated')),
  CONSTRAINT ck_composition_origin CHECK (origin IN ('human','ai','mixed')),
  CONSTRAINT ck_composition_frozen CHECK (
    status <> 'frozen' OR (semantic_hash IS NOT NULL AND reviewed_by IS NOT NULL AND reviewed_at IS NOT NULL))
);
CREATE INDEX ix_composition_steps ON composition_version USING GIN(steps jsonb_path_ops);
CREATE INDEX ix_composition_scope ON composition_version(tenant_id, project_id, status);
CREATE INDEX ix_cv_baseref ON composition_version(based_on_version_id);
CREATE UNIQUE INDEX uq_cv_project_id ON composition_version(project_id, id);

CREATE TABLE composition_review (
  id char(26) PRIMARY KEY,
  tenant_id varchar(64) NOT NULL DEFAULT 'default',
  project_id char(26) NOT NULL,
  composition_version_id char(26) NOT NULL,
  reviewer_id char(26) NOT NULL REFERENCES app_user(id),
  decision varchar(24) NOT NULL,
  comment text,
  origin_at_review varchar(16) NOT NULL,
  ai_confidence numeric(4,3),
  reviewed_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT fk_cr_cv FOREIGN KEY (project_id, composition_version_id) REFERENCES composition_version(project_id, id),
  CONSTRAINT ck_review_decision CHECK (decision IN ('approve','reject','request_changes')),
  CONSTRAINT ck_review_origin CHECK (origin_at_review IN ('human','ai','mixed'))
);
CREATE INDEX ix_composition_review ON composition_review(composition_version_id, reviewed_at DESC);

CREATE TABLE case_composition_binding (
  id char(26) PRIMARY KEY,
  tenant_id varchar(64) NOT NULL DEFAULT 'default',
  project_id char(26) NOT NULL,
  case_id char(26) NOT NULL,
  composition_version_id char(26) NOT NULL,
  role varchar(16) NOT NULL DEFAULT 'primary',
  bound_by char(26) NOT NULL REFERENCES app_user(id),
  bound_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT fk_ccb_case FOREIGN KEY (project_id, case_id) REFERENCES test_case(project_id, id),
  CONSTRAINT fk_ccb_cv FOREIGN KEY (project_id, composition_version_id) REFERENCES composition_version(project_id, id),
  CONSTRAINT uq_case_composition UNIQUE (case_id, composition_version_id),
  CONSTRAINT ck_binding_role CHECK (role IN ('primary','variant'))
);
CREATE UNIQUE INDEX uq_case_primary_composition ON case_composition_binding(case_id) WHERE role = 'primary';

-- ================= C. execution domain =================
CREATE TABLE task_case (
  id char(26) PRIMARY KEY,
  tenant_id varchar(64) NOT NULL DEFAULT 'default',
  project_id char(26) NOT NULL,
  task_id char(26) NOT NULL,
  case_id char(26) NOT NULL,
  seq integer NOT NULL,
  case_snapshot jsonb NOT NULL,
  case_hash char(64) NOT NULL,
  execution_kind varchar(16) NOT NULL,
  script_id char(26),
  script_version integer,
  script_content_hash char(64),
  composition_version_id char(26),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT fk_tc_task FOREIGN KEY (project_id, task_id) REFERENCES task(project_id, id),
  CONSTRAINT fk_tc_case FOREIGN KEY (project_id, case_id) REFERENCES test_case(project_id, id),
  CONSTRAINT uq_task_case UNIQUE (task_id, case_id),
  CONSTRAINT uq_task_case_seq UNIQUE (task_id, seq),
  CONSTRAINT ck_task_case_kind CHECK (execution_kind IN ('SCRIPT','COMPOSITION')),
  CONSTRAINT ck_task_case_unit CHECK (
    (execution_kind = 'SCRIPT' AND script_id IS NOT NULL AND script_version IS NOT NULL
       AND script_content_hash IS NOT NULL AND composition_version_id IS NULL)
    OR
    (execution_kind = 'COMPOSITION' AND composition_version_id IS NOT NULL
       AND script_id IS NULL AND script_version IS NULL AND script_content_hash IS NULL))
);
ALTER TABLE task_case
  ADD CONSTRAINT fk_tc_script FOREIGN KEY (project_id, script_id) REFERENCES script(project_id, id),
  ADD CONSTRAINT fk_tc_cv FOREIGN KEY (project_id, composition_version_id)
    REFERENCES composition_version(project_id, id);

ALTER TABLE attempt
  ADD CONSTRAINT fk_attempt_run FOREIGN KEY (project_id, run_id) REFERENCES run(project_id, id),
  ADD CONSTRAINT fk_attempt_task_case FOREIGN KEY (task_case_id) REFERENCES task_case(id),
  ADD CONSTRAINT fk_attempt_device FOREIGN KEY (device_id) REFERENCES device(id),
  ADD CONSTRAINT fk_attempt_composition FOREIGN KEY (project_id, composition_version_id)
    REFERENCES composition_version(project_id, id),
  ADD CONSTRAINT ck_attempt_exec_unit CHECK (
    (execution_kind = 'SCRIPT' AND composition_version_id IS NULL)
    OR (execution_kind = 'COMPOSITION' AND composition_version_id IS NOT NULL)) NOT VALID;

CREATE TABLE step_execution (
  id char(26) PRIMARY KEY,
  tenant_id varchar(64) NOT NULL DEFAULT 'default',
  project_id char(26) NOT NULL,
  attempt_id char(26) NOT NULL,
  seq integer NOT NULL,
  step_impl_version_id char(26) NOT NULL,
  params_resolved jsonb NOT NULL,
  symbol_resolution jsonb NOT NULL DEFAULT '[]',
  started_at timestamptz NOT NULL,
  finished_at timestamptz,
  outcome varchar(16),
  error_code varchar(64),
  evidence_hash char(64),
  CONSTRAINT fk_se_attempt FOREIGN KEY (project_id, attempt_id) REFERENCES attempt(project_id, id),
  CONSTRAINT fk_se_siv FOREIGN KEY (project_id, step_impl_version_id) REFERENCES step_impl_version(project_id, id),
  CONSTRAINT uq_step_execution_seq UNIQUE (attempt_id, seq),
  CONSTRAINT ck_step_execution_outcome CHECK (
    outcome IS NULL OR outcome IN ('PASS','FAIL','ERROR','SKIPPED','BLOCKED'))
);
CREATE INDEX ix_step_execution_attempt ON step_execution(attempt_id, seq);

CREATE TABLE judge_review (
  id char(26) PRIMARY KEY,
  tenant_id varchar(64) NOT NULL DEFAULT 'default',
  project_id char(26) NOT NULL,
  attempt_id char(26) NOT NULL,
  reviewer_id char(26) NOT NULL REFERENCES app_user(id),
  from_verdict varchar(16) NOT NULL DEFAULT 'NOT_TESTED',
  to_verdict varchar(16) NOT NULL,
  reason text NOT NULL,
  evidence_refs jsonb NOT NULL DEFAULT '[]',
  reviewed_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT fk_jr_attempt FOREIGN KEY (project_id, attempt_id) REFERENCES attempt(project_id, id),
  CONSTRAINT ck_judge_review_from CHECK (from_verdict = 'NOT_TESTED'),
  CONSTRAINT ck_judge_review_to CHECK (to_verdict IN ('PASS','FAIL','INCONCLUSIVE','NOT_APPLICABLE'))
);
CREATE INDEX ix_judge_review_attempt ON judge_review(attempt_id, reviewed_at DESC);
-- FIX-4: one resolve per attempt
CREATE UNIQUE INDEX uq_judge_one_resolve ON judge_review(attempt_id);

CREATE TABLE run_resource (
  id char(26) PRIMARY KEY,
  tenant_id varchar(64) NOT NULL DEFAULT 'default',
  project_id char(26) NOT NULL,
  run_id char(26) NOT NULL,
  device_id char(26) NOT NULL,
  seq integer NOT NULL,
  lock_id char(26),
  acquired_at timestamptz NOT NULL DEFAULT now(),
  released_at timestamptz,
  CONSTRAINT fk_rr_run FOREIGN KEY (project_id, run_id) REFERENCES run(project_id, id),
  CONSTRAINT fk_rr_device FOREIGN KEY (project_id, device_id) REFERENCES device(project_id, id),
  CONSTRAINT uq_run_resource UNIQUE (run_id, device_id),
  CONSTRAINT uq_run_resource_seq UNIQUE (run_id, seq)
);
CREATE INDEX ix_run_resource_device ON run_resource(device_id, released_at);

CREATE TABLE idempotency_record (
  id char(26) PRIMARY KEY,
  tenant_id varchar(64) NOT NULL DEFAULT 'default',
  project_id char(26) NOT NULL REFERENCES project(id),
  scope varchar(64) NOT NULL,
  idem_key varchar(128) NOT NULL,
  request_hash char(64) NOT NULL,
  state varchar(16) NOT NULL DEFAULT 'IN_PROGRESS',
  response jsonb,
  resource_id char(26),
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  CONSTRAINT uq_idempotency_scope UNIQUE (tenant_id, project_id, scope, idem_key),
  CONSTRAINT ck_idempotency_state CHECK (state IN ('IN_PROGRESS','COMPLETED','FAILED'))
);
CREATE INDEX ix_idempotency_expiry ON idempotency_record(expires_at);

-- ================= D. immutability & transition guards =================
CREATE FUNCTION reject_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION '% is append-only/immutable', TG_TABLE_NAME; END $$;

CREATE FUNCTION guard_task_case_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_status varchar(16); v_comp_status varchar(16);
BEGIN
  IF TG_OP IN ('UPDATE','DELETE') THEN
    SELECT status INTO v_status FROM task WHERE id = OLD.task_id;
    IF v_status IS DISTINCT FROM 'DRAFT' THEN
      RAISE EXCEPTION 'task_case snapshot is immutable after task leaves DRAFT';
    END IF;
  END IF;
  IF TG_OP IN ('INSERT','UPDATE') THEN
    SELECT status INTO v_status FROM task WHERE id = NEW.task_id;
    IF v_status IS DISTINCT FROM 'DRAFT' THEN
      RAISE EXCEPTION 'task_case snapshot is immutable after task leaves DRAFT';
    END IF;
    IF TG_OP IN ('INSERT','UPDATE') AND NEW.execution_kind = 'COMPOSITION' THEN
      SELECT status INTO v_comp_status FROM composition_version WHERE id = NEW.composition_version_id;
      IF v_comp_status IS DISTINCT FROM 'frozen' THEN
        RAISE EXCEPTION 'task_case may bind only a frozen composition version';
      END IF;
    END IF;
  END IF;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END $$;
CREATE TRIGGER trg_task_case_guard BEFORE INSERT OR UPDATE OR DELETE ON task_case
  FOR EACH ROW EXECUTE FUNCTION guard_task_case_mutation();
CREATE TRIGGER trg_symbol_version_immutable BEFORE UPDATE OR DELETE ON symbol_version
  FOR EACH ROW EXECUTE FUNCTION reject_mutation();
CREATE TRIGGER trg_composition_review_append BEFORE UPDATE OR DELETE ON composition_review
  FOR EACH ROW EXECUTE FUNCTION reject_mutation();

-- reject approve-by-creator at insert time so failed attempts do not poison
-- later freeze decisions
CREATE FUNCTION guard_composition_review_insert() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.decision = 'approve' AND EXISTS (
    SELECT 1 FROM composition_version cv
    WHERE cv.id = NEW.composition_version_id AND cv.created_by = NEW.reviewer_id
  ) THEN
    RAISE EXCEPTION 'creator cannot approve own composition';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_composition_review_insert BEFORE INSERT ON composition_review
  FOR EACH ROW EXECUTE FUNCTION guard_composition_review_insert();
CREATE TRIGGER trg_judge_review_append BEFORE UPDATE OR DELETE ON judge_review
  FOR EACH ROW EXECUTE FUNCTION reject_mutation();

CREATE FUNCTION guard_composition_version() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE n_approvals int; n_distinct_reviewers int;
BEGIN
  IF OLD.status = 'draft' AND NEW.status NOT IN ('draft','review','deprecated') THEN
    RAISE EXCEPTION 'draft must enter review before freeze';
  ELSIF OLD.status = 'review' AND NEW.status NOT IN ('review','draft','frozen','deprecated') THEN
    RAISE EXCEPTION 'illegal review transition';
  ELSIF OLD.status = 'frozen' AND NEW.status NOT IN ('frozen','deprecated') THEN
    RAISE EXCEPTION 'frozen version may only be deprecated';
  ELSIF OLD.status = 'deprecated' AND NEW.status <> 'deprecated' THEN
    RAISE EXCEPTION 'deprecated version is terminal';
  END IF;
  IF OLD.status IN ('review','frozen','deprecated') AND (
       NEW.steps IS DISTINCT FROM OLD.steps OR NEW.origin IS DISTINCT FROM OLD.origin
       OR NEW.version IS DISTINCT FROM OLD.version OR NEW.composition_id IS DISTINCT FROM OLD.composition_id
       OR NEW.based_on_version_id IS DISTINCT FROM OLD.based_on_version_id) THEN
    RAISE EXCEPTION 'reviewed composition content is immutable';
  END IF;
  -- FIX-5: freeze requires approve review(s); ai/mixed requires 2 distinct
  -- reviewers, and no reviewer may be the creator.
  IF NEW.status = 'frozen' THEN
    SELECT count(*) FILTER (WHERE decision='approve'),
           count(DISTINCT reviewer_id)
      INTO n_approvals, n_distinct_reviewers
      FROM composition_review WHERE composition_version_id = OLD.id;
    IF n_approvals < 1 THEN
      RAISE EXCEPTION 'freeze requires an approve composition_review record';
    END IF;
    IF OLD.origin IN ('ai','mixed') AND n_distinct_reviewers < 2 THEN
      RAISE EXCEPTION 'ai/mixed origin requires two distinct reviewers';
    END IF;
    IF EXISTS (SELECT 1 FROM composition_review
               WHERE composition_version_id = OLD.id
                 AND reviewer_id = OLD.created_by AND decision = 'approve') THEN
      RAISE EXCEPTION 'creator cannot approve own composition';
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_composition_version_guard BEFORE UPDATE ON composition_version
  FOR EACH ROW EXECUTE FUNCTION guard_composition_version();

CREATE FUNCTION guard_composition_version_delete() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.status IN ('frozen','deprecated') THEN
    RAISE EXCEPTION 'frozen/deprecated composition versions are retained for replay';
  END IF;
  RETURN OLD;
END $$;
CREATE TRIGGER trg_composition_version_delete BEFORE DELETE ON composition_version
  FOR EACH ROW EXECUTE FUNCTION guard_composition_version_delete();

CREATE FUNCTION guard_case_composition_binding() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM composition_version
                 WHERE id = NEW.composition_version_id AND status = 'frozen') THEN
    RAISE EXCEPTION 'case may bind only a frozen composition version';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_case_composition_binding_guard
  BEFORE INSERT OR UPDATE ON case_composition_binding
  FOR EACH ROW EXECUTE FUNCTION guard_case_composition_binding();

-- ================= E. RLS =================
CREATE FUNCTION app_has_tenant(p_tenant_id varchar(64))
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT p_tenant_id = current_setting('app.tenant_id', true) $$;

CREATE FUNCTION app_has_project(p_project_id char(26))
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT p_project_id::text = ANY (
    string_to_array(coalesce(current_setting('app.project_ids', true), ''), ',')) $$;

DO $$
DECLARE v_table text;
BEGIN
  FOREACH v_table IN ARRAY ARRAY[
    'project_member','test_case','script','script_version','case_script_binding',
    'parameter_set','scenario','device','task','task_case','run','attempt','evidence',
    'timing_sample','verdict_record','resource_lock','step_registry','step_impl_version',
    'step_sample','symbol_def','symbol_version','symbol_alias','composition',
    'composition_version','composition_review','case_composition_binding',
    'step_execution','judge_review','run_resource','idempotency_record'
  ] LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', v_table);
    EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', v_table);
    EXECUTE format('DROP POLICY IF EXISTS tenant_project_isolation ON %I', v_table);
    EXECUTE format(
      'CREATE POLICY tenant_project_isolation ON %I
       USING (app_has_tenant(tenant_id) AND app_has_project(project_id))
       WITH CHECK (app_has_tenant(tenant_id) AND app_has_project(project_id))', v_table);
  END LOOP;
END $$;

ALTER TABLE project ENABLE ROW LEVEL SECURITY;
ALTER TABLE project FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_project_isolation ON project
  USING (app_has_tenant(tenant_id) AND app_has_project(id))
  WITH CHECK (app_has_tenant(tenant_id) AND app_has_project(id));

ALTER TABLE app_user ENABLE ROW LEVEL SECURITY;
ALTER TABLE app_user FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON app_user
  USING (app_has_tenant(tenant_id)) WITH CHECK (app_has_tenant(tenant_id));

ALTER TABLE audit_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_log FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_project_isolation ON audit_log
  USING (app_has_tenant(tenant_id) AND project_id IS NOT NULL AND app_has_project(project_id))
  WITH CHECK (app_has_tenant(tenant_id) AND project_id IS NOT NULL AND app_has_project(project_id));

ALTER TABLE blob_ref ENABLE ROW LEVEL SECURITY;
ALTER TABLE blob_ref FORCE ROW LEVEL SECURITY;
ALTER TABLE event_outbox ENABLE ROW LEVEL SECURITY;
ALTER TABLE event_outbox FORCE ROW LEVEL SECURITY;

-- ================= F. optional time-series =================
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'timescaledb') THEN
    BEGIN
      CREATE EXTENSION IF NOT EXISTS timescaledb;
      PERFORM create_hypertable('timing_sample', 'ts',
        chunk_time_interval => INTERVAL '7 days', migrate_data => TRUE, if_not_exists => TRUE);
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'timescaledb present but not usable (preload/permission): %', SQLERRM;
    END;
  ELSE
    RAISE NOTICE 'timescaledb unavailable: timing_sample remains a plain table';
  END IF;
END $$;

-- ================= G. smoke seed =================
INSERT INTO app_user (id, tenant_id, display_name)
VALUES (lpad('U', 26, '0')::char(26), 'default', 'seed-admin')
ON CONFLICT DO NOTHING;
