#!/usr/bin/env bash

# Safe cleanup of orphan submission graphs in AllegroGraph.
#
# Default mode is dry-run (no data changes).
# Apply mode performs:
# 1) Backup repository
# 2) Freeze orphan graph list
# 3) Drop orphan graphs
# 4) Verify counts
# 5) Optional maintenance (purge + optimize)

set -euo pipefail

SERVICE="agraph-ut"
REPO="ontoportal_test"
APPLY=0
RUN_MAINTENANCE=1
SKIP_BACKUP=0

usage() {
  cat <<'EOF'
Usage:
  scripts/cleanup_agraph_orphans.sh [options]

Options:
  --apply                 Execute cleanup (default is dry-run)
  --service NAME          Docker Compose service name (default: agraph-ut)
  --repo NAME             AllegroGraph repository (default: ontoportal_test)
  --skip-maintenance      Skip purge-deleted-triples and optimize
  --skip-backup           Skip backup step in apply mode (not recommended)
  -h, --help              Show this help

Examples:
  Dry-run only:
    scripts/cleanup_agraph_orphans.sh

  Apply cleanup with defaults:
    scripts/cleanup_agraph_orphans.sh --apply

  Apply cleanup for custom repo/service:
    scripts/cleanup_agraph_orphans.sh --apply --service agraph-ut --repo ontoportal_test
EOF
}

log() {
  printf '[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
  log "ERROR: $*"
  exit 1
}

run_agraph() {
  docker compose exec -T "$SERVICE" bash -lc "$1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)
      APPLY=1
      ;;
    --service)
      shift
      [[ $# -gt 0 ]] || die "Missing value for --service"
      SERVICE="$1"
      ;;
    --repo)
      shift
      [[ $# -gt 0 ]] || die "Missing value for --repo"
      REPO="$1"
      ;;
    --skip-maintenance)
      RUN_MAINTENANCE=0
      ;;
    --skip-backup)
      SKIP_BACKUP=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
  shift
done

command -v docker >/dev/null 2>&1 || die "docker is required"

if [[ ! -f "docker-compose.yml" ]]; then
  die "Run this script from the project root where docker-compose.yml exists"
fi

log "Checking container and repository access"
if ! docker compose ps "$SERVICE" >/dev/null 2>&1; then
  die "Service '$SERVICE' not found in docker compose"
fi

run_agraph "agtool triple-count '$REPO' >/dev/null" || die "Cannot access repository '$REPO' in service '$SERVICE'"

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_DIR_IN_CONTAINER="/agraph/data/backups"
ORPHAN_LIST_PATH="$BACKUP_DIR_IN_CONTAINER/orphan_graphs_${TIMESTAMP}.tsv"
BACKUP_ARCHIVE_PATH="$BACKUP_DIR_IN_CONTAINER/${REPO}_${TIMESTAMP}.agarch"

# 1) Freeze orphan graph list (same selection criteria used during manual cleanup).
log "Building orphan graph list"
run_agraph "
set -e
mkdir -p '$BACKUP_DIR_IN_CONTAINER'
cat > /tmp/orphan_graphs.rq <<'SPARQL'
SELECT ?g (COUNT(*) AS ?c)
WHERE {
  GRAPH ?g { ?s ?p ?o }
  FILTER(CONTAINS(STR(?g), '/ontologies/') && CONTAINS(STR(?g), '/submissions/'))
  FILTER NOT EXISTS {
    GRAPH <http://api:9393/metadata/OntologySubmission> { ?g ?mp ?mo }
  }
}
GROUP BY ?g
ORDER BY DESC(?c)
SPARQL
agtool query --output-format sparql-tsv '$REPO' /tmp/orphan_graphs.rq > '$ORPHAN_LIST_PATH'
"

ORPHAN_GRAPHS="$(run_agraph "grep -c '^<http' '$ORPHAN_LIST_PATH' || true")"
ORPHAN_TRIPLES="$(run_agraph "awk 'BEGIN{s=0} /^<http/{s+=\$2} END{print s+0}' '$ORPHAN_LIST_PATH'")"
TOTAL_BEFORE="$(run_agraph "agtool triple-count '$REPO'")"

log "Current triple-count: $TOTAL_BEFORE"
log "Orphan graphs found: $ORPHAN_GRAPHS"
log "Orphan triples found: $ORPHAN_TRIPLES"
log "Orphan list saved: $ORPHAN_LIST_PATH"

if [[ "$ORPHAN_GRAPHS" -eq 0 ]]; then
  log "No orphan graphs detected. Nothing to clean."
  exit 0
fi

if [[ "$APPLY" -ne 1 ]]; then
  log "Dry-run mode: no data changed."
  log "Re-run with --apply to execute backup + cleanup."
  exit 0
fi

# 2) Backup before deletion.
if [[ "$SKIP_BACKUP" -eq 0 ]]; then
  log "Creating backup archive: $BACKUP_ARCHIVE_PATH"
  run_agraph "
set -e
mkdir -p '$BACKUP_DIR_IN_CONTAINER'
agtool archive backup '$REPO' '$BACKUP_ARCHIVE_PATH'
"
  log "Backup completed"
else
  log "WARNING: --skip-backup enabled; proceeding without backup"
fi

# 3) Delete orphan graphs only.
log "Deleting orphan graphs"
run_agraph "
set -e
count=0
while IFS=$'\t' read -r g c; do
  case \"\$g\" in
    \<http*) ;;
    *) continue ;;
  esac
  agtool query '$REPO' - <<EOF
DROP GRAPH \$g
EOF
  count=\$((count+1))
done < '$ORPHAN_LIST_PATH'
echo \"Dropped graphs: \$count\"
"

# 4) Verify post-cleanup state.
TOTAL_AFTER="$(run_agraph "agtool triple-count '$REPO'")"
ORPHAN_AFTER="$(run_agraph "
cat > /tmp/orphan_count.rq <<'SPARQL'
SELECT (COUNT(*) AS ?orphanTriples)
WHERE {
  GRAPH ?g { ?s ?p ?o }
  FILTER(CONTAINS(STR(?g), '/ontologies/') && CONTAINS(STR(?g), '/submissions/'))
  FILTER NOT EXISTS {
    GRAPH <http://api:9393/metadata/OntologySubmission> { ?g ?mp ?mo }
  }
}
SPARQL
agtool query --output-format count '$REPO' /tmp/orphan_count.rq | tail -n1 | tr -d '[:space:]'
")"

if [[ ! "$ORPHAN_AFTER" =~ ^[0-9]+$ ]]; then
  ORPHAN_AFTER="unknown"
fi

log "Post-cleanup triple-count: $TOTAL_AFTER"
log "Post-cleanup orphan triples: $ORPHAN_AFTER"

# 5) Optional maintenance.
if [[ "$RUN_MAINTENANCE" -eq 1 ]]; then
  log "Running maintenance: purge-deleted-triples + optimize"
  run_agraph "agtool purge-deleted-triples '$REPO' || true"
  run_agraph "agtool optimize '$REPO' || true"
  log "Maintenance triggered (may continue asynchronously in AllegroGraph)"
else
  log "Maintenance skipped"
fi

log "Cleanup completed successfully"
