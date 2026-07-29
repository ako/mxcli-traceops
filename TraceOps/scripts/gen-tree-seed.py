#!/usr/bin/env python3
"""Generate the TraceOps requirement-tree seed microflows from the mockup data.

The tree, the roll() rollup and the cell formatting are transcribed from
`Requirements Delivery Tracker.dc.html` so the Mendix app shows byte-identical
numbers to the prototype.
"""
import re

# n(id, title, kind, status, opts) — mirrors the mockup's n() helper.
def n(i, t, kind, st, pr=(), vio=(), art=0, tp=0, tf=0, own='—', desc='', kids=()):
    return dict(id=i, t=t, kind=kind, st=st, pr=list(pr), vio=list(vio),
                art=art, tp=tp, tf=tf, rel='4.2', own=own, desc=desc, kids=list(kids))

TREE = [
 n('MES','Production Execution (MES Core)','epic','dev',own='M. Koelewijn',
   desc='Shop-floor order execution, routing and confirmation for discrete and batch plants.',kids=[
  n('MES-1','Work order lifecycle','cap','dev',own='M. Koelewijn',kids=[
   n('MES-1-1','Order release from ERP','feat','verified',own='A. Devos',pr=['ARC-3','ARC-7'],art=6,tp=22,tf=0,kids=[
    n('REQ-MES-1-1-1','Idempotent order intake on SAP IDoc replay','req','verified',pr=['ARC-3'],art=3,tp=9,tf=0,own='A. Devos',
      desc='A duplicate LOIPRO IDoc for an already-released order must not create a second work order; the intake handler keys on (plant, orderNo, revision).'),
    n('REQ-MES-1-1-2','Reject release when routing revision is unresolved','req','verified',pr=['ARC-3','ARC-7'],art=2,tp=7,tf=0,own='A. Devos'),
    n('REQ-MES-1-1-3','Release audit event on every state change','req','verified',pr=['ARC-9'],art=1,tp=6,tf=0,own='A. Devos')]),
   n('MES-1-2','Order state machine','feat','built',own='M. Koelewijn',pr=['ARC-1','ARC-4'],art=9,tp=31,tf=2,kids=[
    n('REQ-MES-1-2-1','States: created → released → active → held → complete','req','built',pr=['ARC-1'],art=4,tp=14,tf=0,own='S. Bakker'),
    n('REQ-MES-1-2-2','Illegal transitions rejected with domain error','req','built',pr=['ARC-1','ARC-4'],art=3,tp=11,tf=2,own='S. Bakker',
      desc='Any transition not present in the transition table must raise WorkOrderStateError and leave state unchanged. 2 tests currently failing on concurrent hold + complete.'),
    n('REQ-MES-1-2-3','Hold reasons configurable per plant','req','dev',pr=['ARC-6'],art=2,tp=6,tf=0,own='S. Bakker')]),
   n('MES-1-3','Operation confirmation','feat','dev',own='M. Koelewijn',pr=['ARC-1','ARC-5'],vio=['ARC-5'],art=5,tp=12,tf=3,
     desc='Operators confirm yield, scrap and labour time against routing operations; confirmations post back to ERP asynchronously.',kids=[
    n('REQ-MES-1-3-1','Partial confirmation with yield and scrap split','req','built',pr=['ARC-1'],art=3,tp=8,tf=0,own='J. Peters'),
    n('REQ-MES-1-3-2','Offline confirmation buffer on terminal (24h)','req','dev',pr=['ARC-5','ARC-8'],vio=['ARC-5'],art=2,tp=4,tf=3,own='J. Peters',
      desc='Terminal must queue confirmations locally when the MES backend is unreachable and replay in order once connectivity returns. Current implementation writes to unencrypted IndexedDB — violates ARC-5.'),
    n('REQ-MES-1-3-3','Confirmation reversal within same shift','req','specified',pr=['ARC-1'],own='J. Peters'),
    n('REQ-MES-1-3-4','Labour time capture per operator badge','req','draft',own='—')]),
   n('MES-1-4','Order scheduling board','feat','mapped',own='M. Koelewijn',pr=['ARC-2'],art=0,tp=0,tf=0,kids=[
    n('REQ-MES-1-4-1','Drag-reschedule with capacity warning','req','mapped',pr=['ARC-2'],own='L. Haan'),
    n('REQ-MES-1-4-2','Board must render 2000 orders under 400 ms','nfr','mapped',pr=['ARC-2','ARC-10'],own='L. Haan')])]),
  n('MES-2','Material traceability','cap','built',own='A. Devos',pr=['ARC-3','ARC-9'],art=11,tp=38,tf=1,kids=[
   n('MES-2-1','Genealogy record per batch','feat','built',pr=['ARC-9'],art=6,tp=21,tf=0,own='A. Devos'),
   n('MES-2-2','Forward/backward trace query under 2 s','nfr','built',pr=['ARC-10'],art=5,tp=17,tf=1,own='A. Devos')]),
  n('MES-3','Shop-floor terminal UX','cap','dev',own='L. Haan',pr=['ARC-6','ARC-11'],art=7,tp=9,tf=4,kids=[
   n('MES-3-1','Glove-operable touch targets ≥ 48 px','nfr','built',pr=['ARC-11'],art=2,tp=5,tf=0,own='L. Haan'),
   n('MES-3-2','Single-hand workflow for confirmation','feat','dev',pr=['ARC-11'],art=3,tp=4,tf=4,own='L. Haan'),
   n('MES-3-3','Kiosk auto-logout after 90 s idle','req','specified',pr=['ARC-5'],own='L. Haan')])]),

 n('QMS','Quality Management','epic','dev',own='R. Visser',
   desc='SPC, non-conformance handling and quality dashboards for line and plant quality engineers.',kids=[
  n('QMS-1','Inspection plans','cap','verified',own='R. Visser',pr=['ARC-3','ARC-6'],art=8,tp=26,tf=0,kids=[
   n('QMS-1-1','Plan versioning bound to part revision','feat','verified',pr=['ARC-3'],art=4,tp=13,tf=0,own='R. Visser'),
   n('QMS-1-2','Sampling rules (AQL, skip-lot)','feat','verified',pr=['ARC-6'],art=4,tp=13,tf=0,own='T. Mulder')]),
  n('QMS-2','SPC & control charts','cap','dev',own='T. Mulder',pr=['ARC-2','ARC-10'],art=9,tp=19,tf=5,kids=[
   n('QMS-2-1','Chart engine','feat','dev',pr=['ARC-2','ARC-10'],art=6,tp=14,tf=5,own='T. Mulder',kids=[
    n('REQ-QMS-2-1-1','X-bar / R chart with 8 Nelson rules','req','built',pr=['ARC-2'],art=3,tp=9,tf=0,own='T. Mulder'),
    n('REQ-QMS-2-1-2','Control limits recalculated per subgroup window','req','built',pr=['ARC-2'],art=2,tp=5,tf=0,own='T. Mulder'),
    n('REQ-QMS-2-1-3','Chart streams live values at 1 Hz for 12 characteristics','nfr','dev',pr=['ARC-10','ARC-8'],vio=['ARC-8'],art=1,tp=0,tf=5,own='T. Mulder',
      desc='Live SPC chart must sustain 1 Hz updates for 12 characteristics without dropped frames. Current build polls REST every 250 ms instead of using the event stream — violates ARC-8.'),
    n('REQ-QMS-2-1-4','Out-of-control alarm raises NC within 5 s','req','review',pr=['ARC-2','ARC-9'],art=3,tp=11,tf=1,own='T. Mulder',
      desc='When a Nelson rule triggers, the system must automatically open a non-conformance record referencing the violating subgroup, operator and machine, within 5 seconds of measurement capture.')]),
   n('QMS-2-2','Capability indices (Cp, Cpk, Ppk)','feat','specified',pr=['ARC-2'],own='T. Mulder'),
   n('QMS-2-3','Chart annotation & sign-off trail','feat','draft',own='—')]),
  n('QMS-3','Non-conformance workflow','cap','built',own='R. Visser',pr=['ARC-1','ARC-9'],art=12,tp=34,tf=2,kids=[
   n('QMS-3-1','NC state machine with disposition gates','feat','built',pr=['ARC-1'],art=7,tp=22,tf=0,own='R. Visser'),
   n('QMS-3-2','8D / CAPA linkage','feat','built',pr=['ARC-9'],art=5,tp=12,tf=2,own='K. Smit'),
   n('QMS-3-3','Electronic signature on disposition','nfr','mapped',pr=['ARC-5','ARC-9'],own='K. Smit')])]),

 n('PLM','PLM Integration & Part Master','epic','built',own='S. Bakker',kids=[
  n('PLM-1','Part & BOM synchronisation','cap','built',pr=['ARC-3','ARC-7'],art=10,tp=29,tf=0,own='S. Bakker',kids=[
   n('PLM-1-1','Delta sync from Teamcenter on ECO release','feat','built',pr=['ARC-7'],art=6,tp=18,tf=0,own='S. Bakker'),
   n('PLM-1-2','Effective-dated BOM resolution','feat','built',pr=['ARC-3'],art=4,tp=11,tf=0,own='S. Bakker')]),
  n('PLM-2','Engineering change impact','cap','dev',pr=['ARC-9'],art=4,tp=6,tf=1,own='S. Bakker',kids=[
   n('PLM-2-1','Show affected open work orders per ECO','feat','dev',pr=['ARC-9'],art=4,tp=6,tf=1,own='S. Bakker'),
   n('PLM-2-2','Block release of superseded revisions','req','mapped',pr=['ARC-3'],own='S. Bakker')]),
  n('PLM-3','Document & work-instruction delivery','cap','specified',own='L. Haan',kids=[
   n('PLM-3-1','Serve latest released work instruction to terminal','req','specified',pr=['ARC-7'],own='L. Haan'),
   n('PLM-3-2','Offline cache of instructions per line','req','draft',own='—')])]),

 n('ANA','Analytics & Dashboards','epic','dev',own='K. Smit',kids=[
  n('ANA-1','Manufacturing quality dashboard','cap','dev',pr=['ARC-2','ARC-10'],art=8,tp=15,tf=2,own='K. Smit',kids=[
   n('ANA-1-1','FPY / scrap / rework tiles by line and shift','feat','built',pr=['ARC-2'],art=4,tp=9,tf=0,own='K. Smit'),
   n('ANA-1-2','Pareto of defect codes with drill to NC list','feat','dev',pr=['ARC-2'],art=3,tp=6,tf=2,own='K. Smit'),
   n('ANA-1-3','Dashboard first paint under 1.5 s on plant LAN','nfr','dev',pr=['ARC-10'],art=1,tp=0,tf=0,own='K. Smit')]),
  n('ANA-2','OEE & downtime analytics','cap','mapped',pr=['ARC-2'],own='K. Smit',kids=[
   n('ANA-2-1','Downtime reason tree with operator capture','feat','mapped',pr=['ARC-6'],own='K. Smit'),
   n('ANA-2-2','OEE definition configurable per plant','req','specified',pr=['ARC-6'],own='K. Smit')]),
  n('ANA-3','Semantic layer & metric definitions','cap','blocked',pr=['ARC-2','ARC-12'],vio=['ARC-12'],art=2,tp=0,tf=0,own='K. Smit',
    desc='Blocked pending ADR-014 decision on metric ownership; agents produced two conflicting metric definitions for FPY.',kids=[
   n('ANA-3-1','Single source of truth for FPY definition','req','blocked',pr=['ARC-12'],vio=['ARC-12'],art=2,own='K. Smit')])]),

 n('PLT','Platform, Identity & Compliance','epic','built',own='A. Devos',kids=[
  n('PLT-1','Identity & access','cap','verified',pr=['ARC-5'],art=9,tp=27,tf=0,own='A. Devos',kids=[
   n('PLT-1-1','SSO via plant OIDC provider','feat','verified',pr=['ARC-5'],art=5,tp=16,tf=0,own='A. Devos'),
   n('PLT-1-2','Role model: operator, supervisor, quality, admin','feat','verified',pr=['ARC-5','ARC-6'],art=4,tp=11,tf=0,own='A. Devos')]),
  n('PLT-2','Audit trail & 21 CFR Part 11 readiness','cap','built',pr=['ARC-9','ARC-5'],art=7,tp=24,tf=1,own='A. Devos',kids=[
   n('PLT-2-1','Immutable append-only audit store','feat','built',pr=['ARC-9'],art=4,tp=15,tf=0,own='A. Devos'),
   n('PLT-2-2','Audit export signed and time-stamped','req','built',pr=['ARC-9'],art=3,tp=9,tf=1,own='A. Devos')]),
  n('PLT-3','Tenancy & plant isolation','cap','dev',pr=['ARC-4','ARC-5'],art=5,tp=8,tf=0,own='A. Devos',kids=[
   n('PLT-3-1','Row-level plant scoping on every query','nfr','dev',pr=['ARC-4'],art=5,tp=8,tf=0,own='A. Devos'),
   n('PLT-3-2','Cross-plant reporting role with explicit grant','req','specified',pr=['ARC-5'],own='A. Devos')])]),

 n('EDG','Edge & Machine Connectivity','epic','dev',own='J. Peters',kids=[
  n('EDG-1','OPC UA client','cap','dev',pr=['ARC-8','ARC-5'],art=8,tp=14,tf=3,own='J. Peters',kids=[
   n('EDG-1-1','Subscription reconnect with backoff','req','blocked',pr=['ARC-8'],art=3,tp=5,tf=3,own='J. Peters',
     desc='Client must re-establish subscriptions after broker restart with exponential backoff and no duplicate node registrations. 3 tests failing since session CC-4465.'),
   n('EDG-1-2','Certificate rotation without downtime','nfr','dev',pr=['ARC-5'],art=2,tp=4,tf=0,own='J. Peters'),
   n('EDG-1-3','Tag mapping configurable per machine type','feat','built',pr=['ARC-6'],art=3,tp=5,tf=0,own='J. Peters')]),
  n('EDG-2','Store-and-forward buffer','cap','mapped',pr=['ARC-8'],own='J. Peters',kids=[
   n('EDG-2-1','Guaranteed at-least-once delivery to MES','req','mapped',pr=['ARC-8'],own='J. Peters'),
   n('EDG-2-2','Buffer encrypted at rest on edge gateway','nfr','draft',pr=['ARC-5'],own='—')]),
  n('EDG-3','Machine event normalisation','cap','draft',own='—',kids=[
   n('EDG-3-1','Canonical event schema for all machine classes','req','draft',own='—')])]),
]

GUARD_TITLES = {
 'ARC-1':'Explicit domain state machines','ARC-2':'Metrics computed server-side',
 'ARC-3':'Idempotent integration boundaries','ARC-4':'Plant is a hard isolation boundary',
 'ARC-5':'Sensitive data encrypted at rest and in transit','ARC-6':'Plant-level configuration over code branching',
 'ARC-7':'PLM is the master of part and BOM data','ARC-8':'Event-driven over polling',
 'ARC-9':'Everything auditable, append-only','ARC-10':'Stated performance budgets per surface',
 'ARC-11':'Designed for gloves and noise','ARC-12':'One canonical definition per metric'}

EXPANDED = {'MES','QMS','PLM','ANA','PLT','EDG','MES-1','QMS-2'}


def roll(nd):
    if not nd['kids']:
        st = nd['st']
        return dict(leaves=1, verified=1 if st == 'verified' else 0,
                    built=1 if st in ('built', 'review') else 0,
                    dev=1 if st == 'dev' else 0, mapped=1 if nd['pr'] else 0,
                    art=nd['art'], tp=nd['tp'], tf=nd['tf'],
                    vio=len(nd['vio']), blocked=1 if st == 'blocked' else 0)
    acc = dict(leaves=0, verified=0, built=0, dev=0, mapped=0, art=0, tp=0, tf=0, vio=0, blocked=0)
    for k in nd['kids']:
        r = roll(k)
        for x in acc:
            acc[x] += r[x]
    acc['vio'] += len(nd['vio']); acc['art'] += nd['art']
    acc['tp'] += nd['tp']; acc['tf'] += nd['tf']
    return acc


def pct(a, b):
    return round(a / b * 100) if b else 0


def esc(s):
    return s.replace("'", "''")


KIND_LABEL = {'epic': 'EPIC', 'cap': 'CAP', 'feat': 'FEAT', 'req': 'REQ', 'nfr': 'NFR'}
STATUS_LABEL = {'draft': 'draft', 'specified': 'specified', 'mapped': 'mapped', 'dev': 'in session',
                'built': 'built', 'review': 'in review', 'verified': 'verified', 'blocked': 'blocked'}

rows = []          # flattened, depth-first
counter = [0]


def walk(nodes, depth, parent_var, visible):
    for nd in nodes:
        r = roll(nd)
        idx = counter[0]; counter[0] += 1
        var = f'$r{idx}'
        leaf = not nd['kids']
        has_vio = r['vio'] > 0

        if nd['pr']:
            guard = f"{len(nd['pr'])}⚠{r['vio']}" if has_vio else str(len(nd['pr']) if r['mapped'] else 0)
        else:
            guard = f"⚠{r['vio']}" if r['vio'] else '—'

        art_cell = str(r['art']) if r['art'] else '—'
        if r['tp'] + r['tf']:
            tests_cell = f"{r['tp']}/{r['tp'] + r['tf']}" if r['tf'] else str(r['tp'])
        else:
            tests_cell = '—'
        sess_cell = {'dev': 'live', 'blocked': 'failed', 'review': 'review'}.get(nd['st'], '—')
        caret = '' if leaf else ('▼' if nd['id'] in EXPANDED else '▶')

        rows.append(dict(
            var=var, node=nd, r=r, depth=depth, parent=parent_var, leaf=leaf,
            sort=idx, visible=visible, expanded=nd['id'] in EXPANDED,
            guard=guard, art_cell=art_cell, tests_cell=tests_cell,
            sess_cell=sess_cell, caret=caret,
            vpct=pct(r['verified'], r['leaves']), bpct=pct(r['built'], r['leaves']),
            dpct=pct(r['dev'], r['leaves']),
            no_impl=leaf and r['art'] == 0,
            no_test=leaf and r['art'] > 0 and r['tp'] == 0,
        ))
        walk(nd['kids'], depth + 1, var, visible and nd['id'] in EXPANDED)


walk(TREE, 0, None, True)

# ---- emit one microflow per epic so parent variables stay local -------------
out = []
out.append("""/**
 * TraceOps — requirement tree seed.
 *
 * GENERATED by scripts/gen-tree-seed.py from the design prototype. Do not edit by
 * hand; regenerate instead. One microflow per epic keeps each flow's variable
 * count manageable and lets parent references stay local to the flow.
 */
""")

epics = [r for r in rows if r['depth'] == 0]
for e_i, epic in enumerate(epics):
    subtree = [r for r in rows if r['sort'] >= epic['sort'] and
               (e_i + 1 >= len(epics) or r['sort'] < epics[e_i + 1]['sort'])]
    name = epic['node']['id']
    out.append(f"""
/**
 * Seeds the {esc(epic['node']['t'])} subtree ({len(subtree)} nodes).
 */
create or replace microflow TraceOps.SEED_Tree_{name} ()
returns Boolean as $Done
begin
  declare $Done Boolean = true;
""")
    for row in subtree:
        nd, r = row['node'], row['r']
        out.append(f"""  {row['var']} = create TraceOps.Requirement (
    ReqId = '{esc(nd['id'])}', Title = '{esc(nd['t'])}',
    Description = '{esc(nd['desc'])}',
    Kind = TraceOps.ReqKind.{nd['kind']}, Status = TraceOps.ReqStatus.{nd['st']},
    OwnerName = '{esc(nd['own'])}', ReleaseTag = '{nd['rel']}', Revision = 'rev 7 · updated 14:02',
    SortIndex = {row['sort']}, Depth = {row['depth']},
    HasChildren = {'true' if not row['leaf'] else 'false'},
    IsExpanded = {'true' if row['expanded'] else 'false'},
    IsVisible = {'true' if row['visible'] else 'false'},
    ArtifactCount = {nd['art']}, TestsPassed = {nd['tp']}, TestsFailed = {nd['tf']},
    RollLeaves = {r['leaves']}, RollVerified = {r['verified']}, RollBuilt = {r['built']},
    RollDev = {r['dev']}, RollMapped = {r['mapped']}, RollArtifacts = {r['art']},
    RollTestsPassed = {r['tp']}, RollTestsFailed = {r['tf']}, RollViolations = {r['vio']},
    RollBlocked = {r['blocked']},
    CaretLabel = '{row['caret']}', KindLabel = '{KIND_LABEL[nd['kind']]}',
    StatusLabel = '{STATUS_LABEL[nd['st']]}', GuardrailCell = '{row['guard']}',
    ArtifactCell = '{row['art_cell']}', TestsCell = '{row['tests_cell']}',
    SessionCell = '{row['sess_cell']}',
    VerifiedBucket = {round(row['vpct'] / 5)}, BuiltBucket = {round(row['bpct'] / 5)},
    DevBucket = {round(row['dpct'] / 5)}, VerifiedPercent = {row['vpct']},
    IsLeaf = {'true' if row['leaf'] else 'false'},
    HasNoImplementation = {'true' if row['no_impl'] else 'false'},
    HasNoPassingTest = {'true' if row['no_test'] else 'false'},
    HasViolation = {'true' if r['vio'] > 0 else 'false'}
  );
""")
        if row['parent']:
            out.append(f"  set {row['var']}/TraceOps.Requirement_Parent = {row['parent']};\n")
        out.append(f"  commit {row['var']};\n")
        for gi, g in enumerate(nd['pr']):
            out.append(f"""  $l{row['sort']}_{gi} = create TraceOps.GuardrailLink (
    GuardrailRef = '{g}', GuardrailTitle = '{esc(GUARD_TITLES[g])}',
    IsViolation = {'true' if g in nd['vio'] else 'false'}, SortIndex = {gi}
  );
  set $l{row['sort']}_{gi}/TraceOps.GuardrailLink_Requirement = {row['var']};
  commit $l{row['sort']}_{gi};
""")
    out.append("""
  return $Done;
end;
/
""")

with open('/home/user/mxcli-traceops/TraceOps/mdlsource/02-seed-tree.mdl', 'w') as f:
    f.write(''.join(out))

leaves = [r for r in rows if r['leaf']]
print(f"nodes={len(rows)} leaves={len(leaves)} epics={len(epics)}")
print(f"noImpl={sum(1 for r in leaves if r['no_impl'])} "
      f"noTest={sum(1 for r in leaves if r['no_test'])} "
      f"failing={sum(1 for r in leaves if r['node']['tf'] > 0)} "
      f"vioNodes={sum(1 for r in rows if r['node']['vio'])}")
tot = dict(leaves=0, verified=0, built=0, dev=0)
for e in epics:
    for k in tot:
        tot[k] += e['r'][k]
print(f"total leaves={tot['leaves']} verified={tot['verified']} "
      f"verifiedPct={pct(tot['verified'], tot['leaves'])}%")
print("visible rows at start:", sum(1 for r in rows if r['visible']))
