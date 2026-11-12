"""Synthetic offline admission and reconciliation specimens; no hosted execution."""
import copy
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import sys
sys.path.insert(0, str(Path.cwd() / "Tools/ci"))
from test_spend_admission import SpendAdmissionTests, IDENTITY
import spend_admission as spend
import usage_report

out = Path(__file__).resolve().parent
fixture = SpendAdmissionTests()
fixture.setUp()
try:
    selection = dict(mode="diagnostic", platform="linux-x64", component="load", suite="load")
    first = fixture.plan(**selection)
    second_identity = dict(IDENTITY, runAttempt="2")
    second = fixture.plan(**selection, identity=second_identity)
    job_id = "linux-x64/canary"
    accepted = fixture.guard(job_id, **selection, identity=second_identity)
    stale = fixture.guard(job_id, **selection, identity=second_identity, plan=first)
    exhausted = fixture.guard(job_id, **selection, identity=dict(IDENTITY, runAttempt="3"))
    zero = fixture.plan(**selection, policy=spend.load_policy())
    assert accepted["admitted"] and not stale["admitted"] and not exhausted["admitted"] and not zero["admitted"]
    assert first["totals"] == second["totals"]
    jobs = []
    start = datetime(2026, 11, 12, 12, tzinfo=timezone.utc)
    stamp = lambda seconds: (start + timedelta(seconds=seconds)).isoformat()
    for number, row in enumerate(second["jobs"], 1):
        jobs.append({"id":number,"name":row["jobName"],"run_id":100,"run_attempt":1,
            "head_sha":"a"*40,"status":"completed","conclusion":"failure" if row["id"] == job_id else "success",
            "runner_group_name":row["group"],"created_at":stamp(-10),"started_at":stamp(0),"completed_at":stamp(61),
            "steps":[{"name":"Checkout","started_at":stamp(0),"completed_at":stamp(5),"conclusion":"success"},
                     {"name":"setup-native","started_at":stamp(5),"completed_at":stamp(35),"conclusion":"success"},
                     {"name":"Upload evidence","started_at":stamp(35),"completed_at":stamp(60),"conclusion":"success"}]})
    rerun = copy.deepcopy(next(job for job in jobs if job["conclusion"] == "failure"))
    rerun.update(id=1000,run_attempt=2,conclusion="success")
    jobs.append(rerun)
    report = usage_report.reconcile(second,jobs)
    assert report["status"] == "complete" and len(report["failedJobIDsAllAttempts"]) == 1
    assert report["invoiceReconciled"] is False
    for name,value in {"plan-first":first,"plan-second":second,"guard-second":accepted,
                       "guard-stale":stale,"guard-exhausted":exhausted,"plan-zero":zero,
                       "observed-jobs":jobs,"usage":report}.items():
        out.joinpath(name+".json").write_text(json.dumps(value,indent=2,sort_keys=True)+"\n")
    out.joinpath("summary.md").write_text(usage_report.markdown(report))
    print(json.dumps({"syntheticFixture":True,"status":"passed","jobCount":len(second["jobs"]),
        "permittedAttempts":2,"cumulativeReservationsUnchanged":True,"staleAndExhaustedRejected":True,
        "remainingCoverage":report["remainingCoverage"],"observedFailedAttemptRetained":True,"hostedExecution":False}))
finally:
    fixture.doCleanups()
