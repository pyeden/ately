import hashlib, json, os, uuid
from contextlib import contextmanager

import psycopg
from fastapi import FastAPI, HTTPException, Header
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

DATABASE_URL = os.environ.get(
    "DATABASE_URL",
    "postgresql://ately:ately@localhost:5432/ately")
TENANT = "default"

app = FastAPI(title="ATEly", version="0.1.0", description="Replayable automotive test execution (PRD v1.2.1 contract)")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])


@contextmanager
def tx(project_ids: list[str]):
    """One transaction; sets RLS context via SET LOCAL."""
    conn = psycopg.connect(DATABASE_URL, autocommit=False)
    try:
        cur = conn.cursor()
        cur.execute("SELECT set_config('app.tenant_id', %s, true)", (TENANT,))
        cur.execute("SELECT set_config('app.project_ids', %s, true)", (",".join(project_ids),))
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def gen_id() -> str:
    return uuid.uuid4().hex[:26].upper()


def sha256s(s) -> str:
    return hashlib.sha256(json.dumps(s, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


# ---------------- models ----------------

class JudgeIn(BaseModel):
    reviewer_id: str
    to_verdict: str          # PASS | FAIL | INCONCLUSIVE | NOT_APPLICABLE
    reason: str


# ---------------- endpoints ----------------

@app.get("/health")
def health():
    with tx([]) as conn, conn.cursor() as cur:
        cur.execute("select 1")
        cur.fetchone()
    return {"ok": True}


@app.post("/seed")
def seed():
    """Create a demo project with one case bound to a script, plus sim device."""
    pid, uid_admin, uid_r1, uid_r2 = gen_id(), gen_id(), gen_id(), gen_id()
    case_id, script_id = gen_id(), gen_id()
    with tx([pid]) as conn, conn.cursor() as cur:
        cur.execute("INSERT INTO project(id,name) VALUES (%s,%s)", (pid, f"demo-{pid[:6].lower()}"))
        for uid, name in ((uid_admin, "admin"), (uid_r1, "reviewer1"), (uid_r2, "reviewer2")):
            cur.execute("INSERT INTO app_user(id,display_name) VALUES (%s,%s)", (uid, name))
        cur.execute("INSERT INTO device(id,project_id,code,driver) VALUES (%s,%s,%s,'sim')",
                    (gen_id(), pid, "SIM-001"))
        script = "import time\ntime.sleep(0.01)\nprint('sim step ok')"
        cur.execute(
            "INSERT INTO script(id,project_id,name) VALUES (%s,%s,%s)", (script_id, pid, "sim-script"))
        cur.execute(
            "INSERT INTO script_version(id,project_id,script_id,version,content,content_hash,created_by)"
            " VALUES (%s,%s,%s,1,%s,%s,%s)",
            (gen_id(), pid, script_id, script, sha256s(script), uid_admin))
        case = {"id": case_id, "code": "TC-001", "title": "sim brake check",
                "steps": ["power sim ECU"], "expected": "ok", "priority": "P1",
                "tags": [], "is_active": True, "precondition": None}
        cur.execute(
            "INSERT INTO test_case(id,project_id,code,title,steps,expected,priority)"
            " VALUES (%s,%s,%s,%s,%s::jsonb,%s,%s)",
            (case_id, pid, case["code"], case["title"], json.dumps(case["steps"]), case["expected"], case["priority"]))
        cur.execute(
            "INSERT INTO case_script_binding(id,project_id,case_id,script_id,script_version)"
            " VALUES (%s,%s,%s,%s,1)", (gen_id(), pid, case_id, script_id))
    return {"project_id": pid, "case_id": case_id, "script_id": script_id}


@app.post("/projects/{pid}/tasks")
def create_task(pid: str):
    """Materialize the DRAFT task snapshot from active cases (PRD §4.1)."""
    task_id, tc_id = gen_id(), gen_id()
    with tx([pid]) as conn, conn.cursor() as cur:
        cur.execute("""SELECT id FROM test_case
                       WHERE project_id=%s AND is_active
                       ORDER BY priority, code""", (pid,))
        rows = [r[0] for r in cur.fetchall()]
        if not rows:
            raise HTTPException(404, "no active cases; POST /seed first")
        cur.execute("INSERT INTO task(id,project_id,name) VALUES (%s,%s,%s)",
                    (task_id, pid, "demo-task"))
        cur.execute("""SELECT project_id, code, title, precondition, steps, expected,
                              priority, tags, is_active
                       FROM test_case WHERE id=%s""", (rows[0],))
        p, code, title, pre, steps, exp, prio, tags, act = cur.fetchone()
        snap = {"id": rows[0], "code": code, "title": title, "precondition": pre,
                "steps": steps, "expected": exp, "priority": prio, "tags": tags,
                "is_active": act}
        cur.execute("""SELECT b.script_id, b.script_version, sv.content_hash
                       FROM case_script_binding b
                       JOIN script_version sv
                         ON sv.project_id=b.project_id AND sv.script_id=b.script_id
                        AND sv.version=b.script_version
                       WHERE b.case_id=%s""", (rows[0],))
        script_id, script_version, script_hash = cur.fetchone()
        cur.execute(
            """INSERT INTO task_case(id,project_id,task_id,case_id,seq,case_snapshot,
               case_hash,execution_kind,script_id,script_version,script_content_hash)
               VALUES (%s,%s,%s,%s,1,%s::jsonb,%s,'SCRIPT',%s,%s,%s)""",
            (tc_id, pid, task_id, rows[0], json.dumps(snap, sort_keys=True, ensure_ascii=False),
             sha256s(snap), script_id, script_version, script_hash))
    return {"task_id": task_id, "task_case_id": tc_id, "case_hash": sha256s(snap)}


@app.post("/tasks/{task_id}/runs")
def submit_run(task_id: str, idempotency_key: str = Header(default="")):
    """Submit run with 24h idempotency (PRD §5.2), then execute the loop."""
    if not idempotency_key:
        raise HTTPException(400, "Idempotency-Key header required")
    run_id, attempt_id, rid_key = gen_id(), gen_id(), gen_id()
    lock_id = gen_id()
    with tx([]) as conn, conn.cursor() as cur:
        cur.execute("SELECT project_id FROM task WHERE id=%s", (task_id,))
        row = cur.fetchone()
        if not row:
            raise HTTPException(404, "task not found (task is project-scoped)")
        pid = row[0]
    with tx([pid]) as conn, conn.cursor() as cur:
        req_hash = sha256s({"task_id": task_id})
        cur.execute(
            "SELECT state, response, resource_id FROM idempotency_record"
            " WHERE tenant_id=%s AND project_id=%s AND scope=%s AND idem_key=%s",
            (TENANT, pid, "submit-run", idempotency_key))
        rec = cur.fetchone()
        if rec:
            state, resp, rres = rec
            if state == "COMPLETED":
                return {"idempotent": True, "run_id": rres}
            if state == "IN_PROGRESS":
                raise HTTPException(409, "REQUEST_IN_PROGRESS")
            raise HTTPException(409, "IDEMPOTENCY_PREVIOUS_FAILED")
        cur.execute(
            "INSERT INTO idempotency_record(id,project_id,scope,idem_key,request_hash,expires_at)"
            " VALUES (%s,%s,'submit-run',%s,%s, now()+interval '24 hours')",
            (rid_key, pid, idempotency_key, req_hash))
        # device list in ascending order (PRD §5.1)
        cur.execute("SELECT id FROM device WHERE project_id=%s ORDER BY code", (pid,))
        devices = [r[0] for r in cur.fetchall()]
        if not devices:
            raise HTTPException(409, "no devices")
        cur.execute("INSERT INTO run(id,project_id,task_id,device_ids,idempotency_key)"
                    " VALUES (%s,%s,%s,%s::jsonb,%s)",
                    (run_id, pid, task_id, json.dumps(devices), idempotency_key))
        # atomic all-or-nothing resource acquisition via advisory lock per device
        for seq, dev in enumerate(devices, start=1):
            cur.execute("SELECT pg_advisory_xact_lock(hashtextextended(%s, 20261116))", (dev,))
            cur.execute("""UPDATE resource_lock SET released_at=now(),
                             release_reason='EXPIRED_SWEEP'
                           WHERE device_id=%s AND released_at IS NULL AND expires_at<=now()""", (dev,))
            cur.execute("""INSERT INTO resource_lock(id,project_id,device_id,run_id,expires_at)
                           VALUES (%s,%s,%s,%s, now()+interval '60 seconds')""",
                        (lock_id, pid, dev, run_id))
            cur.execute("""INSERT INTO run_resource(id,project_id,run_id,device_id,seq,lock_id)
                           VALUES (%s,%s,%s,%s,%s,%s)""", (gen_id(), pid, run_id, dev, seq, lock_id))
        # snapshot-based attempts
        for seq, (tc_id, case_id, script_id, script_version, script_hash) in enumerate(cur.execute(
                "SELECT id, case_id, script_id, script_version, script_content_hash"
                " FROM task_case WHERE task_id=%s ORDER BY seq", (task_id,)).fetchall(), 1):
            continue
        cur.execute("""INSERT INTO attempt(id,project_id,run_id,task_case_id,case_id,device_id,
                       execution_kind,started_at) VALUES (%s,%s,%s,%s,%s,%s,'SCRIPT',now())""",
                    (attempt_id, pid, run_id, tc_id, case_id, devices[0]))
        cur.execute("UPDATE run SET status='RUNNING' WHERE id=%s", (run_id,))
        cur.execute("UPDATE task SET status='RUNNING' WHERE id=%s AND status='QUEUED'", (task_id,))
        cur.execute("UPDATE task SET status='RUNNING' WHERE id=%s", (task_id,))
        cur.execute("""SELECT script_content_hash, script_id
                       FROM task_case WHERE id=%s""", (tc_id,))
        _hash, script_id = cur.fetchone()
        cur.execute("SELECT content FROM script_version WHERE script_id=%s AND version=1", (script_id,))
        content = cur.fetchone()[0]
        try:
            exec(compile(content, "task_script", "exec"), {"__builtins__": __builtins__}, {})
            outcome, verdict, reason = "PASSED", "PASS", "script ok"
        except Exception as e:                    # noqa: BLE001
            outcome, verdict, reason = "ERROR", "FAIL", str(e)[:500]
            cur.execute("""INSERT INTO verdict_record(id,project_id,attempt_id,verdict,source,reason)
                           VALUES (%s,%s,%s,%s,'auto',%s)""", (gen_id(), pid, attempt_id, "FAIL", reason))
            cur.execute("""UPDATE attempt SET status='ERROR', verdict='FAIL', judge_state='RESOLVED',
                             finished_at=now() WHERE id=%s""", (attempt_id,))
            cur.execute("UPDATE run SET status='FAILED', finished_at=now() WHERE id=%s", (run_id,))
            raise HTTPException(500, f"script error: {reason}") from e
        cur.execute("""UPDATE attempt SET status=%s, verdict=%s, judge_state='RESOLVED',
                       finished_at=now() WHERE id=%s""", (outcome, verdict, attempt_id))
        cur.execute("UPDATE run SET status='SUCCEEDED', finished_at=now() WHERE id=%s", (run_id,))
        cur.execute("UPDATE task SET status='FINISHED' WHERE id=%s", (task_id,))
        # release locks in reverse order
        for dev in reversed(devices):
            cur.execute("""UPDATE resource_lock SET released_at=now(), release_reason='NORMAL'
                           WHERE device_id=%s AND run_id=%s AND released_at IS NULL""", (dev, run_id))
            cur.execute("UPDATE run_resource SET released_at=now() WHERE run_id=%s AND device_id=%s",
                        (run_id, dev))
        rls_semantic = {"run_id": run_id, "attempt_id": attempt_id, "verdict": verdict}
        cur.execute("""UPDATE idempotency_record SET state='COMPLETED', response=%s::jsonb,
                       resource_id=%s WHERE id=%s""",
                    (json.dumps(rls_semantic), run_id, rid_key))
    return {"run_id": run_id, "attempt_id": attempt_id, "verdict": verdict}


@app.get("/runs/{run_id}")
def get_run(run_id: str):
    with tx([]) as conn, conn.cursor() as cur:
        cur.execute("""SELECT r.status, r.task_id, r.device_ids, r.created_at, r.finished_at
                       FROM run r WHERE r.id=%s""", (run_id,))
        row = cur.fetchone()
        if not row:
            raise HTTPException(404, "run not found")
        status, task_id, device_ids, created, finished = row
        return {"run_id": run_id, "task_id": task_id, "status": status,
                "device_ids": device_ids, "created_at": str(created), "finished_at": str(finished)}


@app.post("/attempts/{attempt_id}/judge-reviews")
def judge(attempt_id: str, body: JudgeIn):
    """Human judgment on NEED_HUMAN attempts (PRD §3.2, §6.1)."""
    mapping = {"PASS": "PASSED", "FAIL": "FAILED",
               "INCONCLUSIVE": "ERROR", "NOT_APPLICABLE": "SKIPPED"}
    if body.to_verdict not in mapping:
        raise HTTPException(400, "bad to_verdict")
    with tx([]) as conn, conn.cursor() as cur:
        cur.execute("SELECT project_id FROM attempt WHERE id=%s", (attempt_id,))
        row = cur.fetchone()
        if not row:
            raise HTTPException(404, "attempt not found")
        pid = row[0]
    with tx([pid]) as conn, conn.cursor() as cur:
        cur.execute("""SELECT status, judge_state FROM attempt WHERE id=%s""", (attempt_id,))
        status, judge_state = cur.fetchone()
        if not (status == "NEED_HUMAN" and judge_state == "NEED_HUMAN"):
            raise HTTPException(409, "attempt is not awaiting human judgment")
        jid = gen_id()
        cur.execute("""INSERT INTO judge_review(id,project_id,attempt_id,reviewer_id,to_verdict,reason)
                       VALUES (%s,%s,%s,%s,%s,%s)""",
                    (jid, pid, attempt_id, body.reviewer_id, body.to_verdict, body.reason))
        cur.execute("""UPDATE attempt SET
                         status=%s, verdict=%s, judge_state='RESOLVED', finished_at=now()
                       WHERE id=%s""", (mapping[body.to_verdict], body.to_verdict, attempt_id))
        cur.execute("""INSERT INTO verdict_record(id,project_id,attempt_id,verdict,source,reason)
                       VALUES (%s,%s,%s,%s,'human',%s)""",
                    (gen_id(), pid, attempt_id, body.to_verdict, body.reason))
    return {"judge_review_id": jid, "mapped_status": mapping[body.to_verdict]}
