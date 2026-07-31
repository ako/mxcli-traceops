# PERF001: List widget backed by a microflow datasource
#
# A list widget whose datasource is a microflow gets no query pushdown: the
# runtime cannot translate the grid's search, sort or paging into SQL, so the
# microflow returns its whole result set and the client filters it in memory.
# Every unshown row is still retrieved, transferred and held as browser state.
#
# A view entity keeps the same shaped result but is OQL-backed, so WHERE, ORDER
# BY and LIMIT are pushed down to the database.
#
# This rule exists to test FINDINGS #35 gap 3: it is keyed on widget.microflow_ref,
# which the Starlark widget struct did not expose before the fix.

RULE_ID = "PERF001"
RULE_NAME = "MicroflowDatasourceNoPushdown"
DESCRIPTION = "List widgets should use a database or view-entity datasource, not a microflow"
CATEGORY = "performance"
SEVERITY = "warning"
REQUIRES = ["full"]

# Widget types that render a list and therefore have search/sort/paging to push down.
LIST_WIDGETS = [
    "Forms$ListView",
    "Forms$DataGrid",
    "Forms$Grid",
    "DataGrid2$DatagridWidget",
    "Gallery$Gallery",
]

def check():
    violations = []
    supported = True

    for w in widgets():
        if w.widget_type not in LIST_WIDGETS:
            continue
        # microflow_ref landed in the linter's widget projection with the #35 fix.
        # Degrade to a single explanatory finding on older builds rather than
        # erroring out of every lint run — or, worse, silently reporting nothing.
        ref = getattr(w, "microflow_ref", None)
        if ref == None:
            supported = False
            break
        if ref == "":
            continue

        violations.append(violation(
            message="{} '{}' on {} takes its data from microflow '{}' — no database pushdown, so search, sort and paging happen in memory over the full result set.".format(
                w.widget_type.split("$")[-1], w.name, w.container_qualified_name, ref,
            ),
            location=location(
                module=w.module_name,
                document_type="Page",
                document_name=w.container_qualified_name,
            ),
            suggestion="Express '{}' as a view entity (create or modify view entity ... as (<OQL>)) and bind the widget to it, so WHERE/ORDER BY/LIMIT reach the database.".format(ref),
        ))

    if not supported:
        return [violation(
            message="PERF001 needs widget.microflow_ref, which this mxcli build's linter does not expose (added for FINDINGS #35). Upgrade mxcli to run this rule.",
            location=location(module="TraceOps", document_type="Page", document_name="TraceOps"),
            suggestion="Upgrade mxcli; until then this anti-pattern is only detectable in catalog SQL: SELECT * FROM CATALOG.WIDGETS WHERE WidgetType = 'Forms$ListView' AND MicroflowRef <> ''",
        )]

    return violations
