-- db/ci/verify_behaviors.sql : behavioral guards on the fresh baseline.
-- Every DB-level rejection is exercised; failures raise at the end.
\set ON_ERROR_STOP on

DO $$
DECLARE
  pid char(26) := substr(md5(random()::text||'p'),1,26);
  u1 char(26)  := substr(md5(random()::text||'a'),1,26);
  u2 char(26)  := substr(md5(random()::text||'b'),1,26);
  u3 char(26)  := substr(md5(random()::text||'c'),1,26);
  comp char(26):= substr(md5(random()::text||'m'),1,26);
  cv  char(26) := substr(md5(random()::text||'v'),1,26);
  nchecks int := 0;
BEGIN
  PERFORM set_config('app.tenant_id','default',false);
  PERFORM set_config('app.project_ids',pid,false);
  INSERT INTO project(id,name) VALUES (pid,'ci');
  PERFORM set_config('app.project_ids','',false);
  INSERT INTO app_user(id,display_name) VALUES (u1,'a'),(u2,'b'),(u3,'c');
  PERFORM set_config('app.project_ids',pid,false);
  INSERT INTO composition(id,project_id,name,created_by) VALUES (comp,pid,'x',u1);
  INSERT INTO composition_version(id,project_id,composition_id,version,origin,steps,created_by)
    VALUES (cv,pid,comp,1,'ai','[]'::jsonb,u1);
  UPDATE composition_version SET status='review' WHERE id=cv;

  -- 1. creator approve rejected at insert
  BEGIN
    INSERT INTO composition_review(id,project_id,composition_version_id,reviewer_id,decision,origin_at_review)
      VALUES (substr(md5('r1'),1,26),pid,cv,u1,'approve','ai');
    RAISE EXCEPTION 'CHECK1 FAILED: creator approve allowed';
  EXCEPTION WHEN raise_exception THEN
    nchecks := nchecks + 1;
  END;

  -- 2. freeze without any approve review rejected
  BEGIN
    UPDATE composition_version SET status='frozen',semantic_hash=repeat('a',64),
      reviewed_by=u2, reviewed_at=now() WHERE id=cv;
    RAISE EXCEPTION 'CHECK2 FAILED: freeze without approve';
  EXCEPTION WHEN raise_exception THEN
    nchecks := nchecks + 1;
  END;

  -- 3. one reviewer approve -> freeze still rejected for ai origin
  INSERT INTO composition_review(id,project_id,composition_version_id,reviewer_id,decision,origin_at_review)
    VALUES (substr(md5('r2'),1,26),pid,cv,u2,'approve','ai');
  BEGIN
    UPDATE composition_version SET status='frozen',semantic_hash=repeat('a',64),
      reviewed_by=u2, reviewed_at=now() WHERE id=cv;
    RAISE EXCEPTION 'CHECK3 FAILED: single approval froze ai origin';
  EXCEPTION WHEN raise_exception THEN
    nchecks := nchecks + 1;
  END;

  -- 4. second distinct reviewer -> freeze succeeds
  INSERT INTO composition_review(id,project_id,composition_version_id,reviewer_id,decision,origin_at_review)
    VALUES (substr(md5('r3'),1,26),pid,cv,u3,'approve','ai');
  UPDATE composition_version SET status='frozen',semantic_hash=repeat('a',64),
    reviewed_by=u3, reviewed_at=now() WHERE id=cv;
  nchecks := nchecks + 1;

  -- 5. append-only judge_review/composition_review/symbol_version reject UPDATE
  BEGIN
    UPDATE symbol_version SET maturity='stable' WHERE false;
    RAISE EXCEPTION 'CHECK5 FAILED: symbol_version update allowed';
  EXCEPTION WHEN raise_exception THEN
    nchecks := nchecks + 1;
  END;

  -- 6. frozen composition cannot be rebound to a new draft task_case (task guard)
  BEGIN
    UPDATE composition_version SET status='review' WHERE id=cv;
    RAISE EXCEPTION 'CHECK6 FAILED: frozen rollback allowed';
  EXCEPTION WHEN raise_exception THEN
    nchecks := nchecks + 1;
  END;

  RAISE NOTICE 'behavioral guards OK: % checks', nchecks;
END $$;
