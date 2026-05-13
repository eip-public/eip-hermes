#!/usr/bin/env bash
# installers/hermes/install.sh -- drop-in component orchestrator
#
# Discovers components/*.sh, parses each file's metadata header, builds a run
# plan that respects --skip / --only and auto-pulls `requires:` dependencies,
# then sources each component and calls its run() (and verify(), if defined).
#
# Generic CLI:
#   install.sh                    run all enabled components in prefix order
#   install.sh --list             show component table (name, default, ports, requires)
#   install.sh --only NAME[,...]  run exactly these components plus their requires
#   install.sh --skip NAME[,...]  drop these from the default plan
#   install.sh --with NAME[,...]  add these (default-disabled) components to the default plan
#   install.sh --non-interactive  pass NON_INTERACTIVE=true to components
#   install.sh --force            pass FORCE=true to components
#   install.sh --dry-run          print the resolved plan and exit
#   install.sh --validate         lint every component's metadata header
#   install.sh -h | --help        show this message

set -Eeuo pipefail

INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPONENTS_DIR="$INSTALLER_DIR/components"

# shellcheck disable=SC1091
source "$INSTALLER_DIR/lib/common.sh"
# shellcheck disable=SC1091
set -a; source "$INSTALLER_DIR/defaults.env"; set +a

# ----------------------------- Arg parsing ----------------------------------
ONLY=""
SKIP=""
WITH=""
DRY_RUN=false
DO_LIST=false
DO_VALIDATE=false

usage() {
  sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --list) DO_LIST=true; shift ;;
    --validate) DO_VALIDATE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --only) ONLY="$2"; shift 2 ;;
    --only=*) ONLY="${1#--only=}"; shift ;;
    --skip) SKIP="$2"; shift 2 ;;
    --skip=*) SKIP="${1#--skip=}"; shift ;;
    --with) WITH="$2"; shift 2 ;;
    --with=*) WITH="${1#--with=}"; shift ;;
    --non-interactive) NON_INTERACTIVE=true; shift ;;
    --force) FORCE=true; shift ;;
    *) fail "Unknown option: $1 (try --help)" ;;
  esac
done
export NON_INTERACTIVE FORCE

# --------------------- Component metadata parsing --------------------------
# Each component file starts with:
#   # eip-hermes-component:
#   #   name: ...
#   #   description: ...
#   #   default: enabled|disabled
#   #   ports: PORT:LABEL[,PORT:LABEL...]
#   #   requires: name[,name...]
parse_meta() {
  local file="$1" key="$2"
  awk -v key="$key" '
    /^# eip-hermes-component:[[:space:]]*$/ { in_block = 1; next }
    in_block {
      if (!/^#/) { exit }
      line = $0
      sub(/^#[[:space:]]+/, "", line)
      idx = index(line, ":")
      if (idx == 0) { exit }
      k = substr(line, 1, idx - 1)
      v = substr(line, idx + 1)
      sub(/^[[:space:]]+/, "", v); sub(/[[:space:]]+$/, "", v)
      if (k == key) { print v; exit }
    }
  ' "$file"
}

# Discover components in numeric/lexical prefix order.
mapfile -t COMPONENT_FILES < <(printf '%s\n' "$COMPONENTS_DIR"/[0-9]*.sh 2>/dev/null | sort)
[ "${#COMPONENT_FILES[@]}" -gt 0 ] || fail "No components found in $COMPONENTS_DIR"

declare -A FILE_BY_NAME=()
declare -A DESC_BY_NAME=()
declare -A DEFAULT_BY_NAME=()
declare -A PORTS_BY_NAME=()
declare -A REQUIRES_BY_NAME=()
ORDER=()

for f in "${COMPONENT_FILES[@]}"; do
  name="$(parse_meta "$f" name)"
  [ -n "$name" ] || fail "Component $f is missing 'name:' in its header"
  if [ -n "${FILE_BY_NAME[$name]:-}" ]; then
    fail "Duplicate component name '$name' (in $f and ${FILE_BY_NAME[$name]})"
  fi
  FILE_BY_NAME[$name]="$f"
  DESC_BY_NAME[$name]="$(parse_meta "$f" description)"
  DEFAULT_BY_NAME[$name]="$(parse_meta "$f" default)"
  PORTS_BY_NAME[$name]="$(parse_meta "$f" ports)"
  REQUIRES_BY_NAME[$name]="$(parse_meta "$f" requires)"
  ORDER+=("$name")
done

# ----------------------------- --validate ----------------------------------
validate_components() {
  local errs=0
  for name in "${ORDER[@]}"; do
    local f="${FILE_BY_NAME[$name]}"
    case "${DEFAULT_BY_NAME[$name]}" in
      enabled|disabled) ;;
      *) printf '[FAIL] %s\n' "$name: default must be 'enabled' or 'disabled' (got '${DEFAULT_BY_NAME[$name]}')" >&2; errs=$((errs+1)) ;;
    esac
    [ -n "${DESC_BY_NAME[$name]}" ] || { printf '[FAIL] %s\n' "$name: description is empty" >&2; errs=$((errs+1)); }
    if [ -n "${REQUIRES_BY_NAME[$name]}" ]; then
      local IFS=','
      for dep in ${REQUIRES_BY_NAME[$name]}; do
        dep="${dep// /}"
        [ -n "$dep" ] || continue
        [ -n "${FILE_BY_NAME[$dep]:-}" ] || { printf '[FAIL] %s\n' "$name: requires unknown component '$dep'" >&2; errs=$((errs+1)); }
      done
    fi
  done
  if [ "$errs" -gt 0 ]; then fail "$errs component metadata error(s) found"; fi
  success "All component metadata valid"
}

# ------------------------------- --list ------------------------------------
list_components() {
  printf 'Components in %s\n' "$COMPONENTS_DIR"
  printf '%-16s  %-9s  %-30s  %-20s  %s\n' "NAME" "DEFAULT" "DESCRIPTION" "PORTS" "REQUIRES"
  printf '%-16s  %-9s  %-30s  %-20s  %s\n' "----" "-------" "-----------" "-----" "--------"
  for name in "${ORDER[@]}"; do
    printf '%-16s  %-9s  %-30s  %-20s  %s\n' \
      "$name" \
      "${DEFAULT_BY_NAME[$name]}" \
      "${DESC_BY_NAME[$name]:0:30}" \
      "${PORTS_BY_NAME[$name]:--}" \
      "${REQUIRES_BY_NAME[$name]:--}"
  done
}

# --------------------------- Plan resolution -------------------------------
contains() {
  local needle="$1"; shift
  local hay
  for hay in "$@"; do [ "$hay" = "$needle" ] && return 0; done
  return 1
}

split_csv() {
  local csv="$1"
  csv="${csv// /}"
  if [ -z "$csv" ]; then return 0; fi
  printf '%s\n' "$csv" | tr ',' '\n'
}

resolve_plan() {
  # Reject contradictions up front: a component named in --only or --with
  # AND in --skip is almost certainly a typo; producing a silently-empty
  # plan is worse than a clear error.
  if [ -n "$SKIP" ] && { [ -n "$ONLY" ] || [ -n "$WITH" ]; }; then
    local -a only_list=() with_list=() skip_list=() n s
    while IFS= read -r n; do [ -n "$n" ] && only_list+=("$n"); done < <(split_csv "$ONLY")
    while IFS= read -r n; do [ -n "$n" ] && with_list+=("$n"); done < <(split_csv "$WITH")
    while IFS= read -r n; do [ -n "$n" ] && skip_list+=("$n"); done < <(split_csv "$SKIP")
    for s in "${skip_list[@]}"; do
      if [ "${#only_list[@]}" -gt 0 ] && contains "$s" "${only_list[@]}"; then
        fail "--only and --skip both name '$s' -- pick one"
      fi
      if [ "${#with_list[@]}" -gt 0 ] && contains "$s" "${with_list[@]}"; then
        fail "--with and --skip both name '$s' -- pick one"
      fi
    done
  fi

  local -a base_set=()
  if [ -n "$ONLY" ]; then
    while IFS= read -r n; do
      [ -n "$n" ] || continue
      [ -n "${FILE_BY_NAME[$n]:-}" ] || fail "--only references unknown component '$n'"
      base_set+=("$n")
    done < <(split_csv "$ONLY")
  else
    for name in "${ORDER[@]}"; do
      if [ "${DEFAULT_BY_NAME[$name]}" = "enabled" ]; then
        base_set+=("$name")
      fi
    done
    # --with adds default-disabled components to the default plan without
    # discarding it (unlike --only). Useful for opt-in extras like rdp.
    if [ -n "$WITH" ]; then
      while IFS= read -r n; do
        [ -n "$n" ] || continue
        [ -n "${FILE_BY_NAME[$n]:-}" ] || fail "--with references unknown component '$n'"
        if ! contains "$n" "${base_set[@]}"; then
          base_set+=("$n")
        fi
      done < <(split_csv "$WITH")
    fi
  fi

  if [ -n "$SKIP" ]; then
    while IFS= read -r n; do
      [ -n "$n" ] || continue
      [ -n "${FILE_BY_NAME[$n]:-}" ] || fail "--skip references unknown component '$n'"
    done < <(split_csv "$SKIP")
  fi

  # Auto-pull required dependencies (transitive).
  local -a wanted=("${base_set[@]}")
  local added_any=true
  while [ "$added_any" = true ]; do
    added_any=false
    for name in "${wanted[@]}"; do
      local req="${REQUIRES_BY_NAME[$name]:-}"
      [ -n "$req" ] || continue
      while IFS= read -r dep; do
        [ -n "$dep" ] || continue
        [ -n "${FILE_BY_NAME[$dep]:-}" ] || fail "Component '$name' requires unknown component '$dep'"
        if ! contains "$dep" "${wanted[@]}"; then
          wanted+=("$dep")
          added_any=true
          if ! contains "$dep" "${base_set[@]}"; then
            log "Auto-pulling dep '$dep' (required by '$name')"
          fi
        fi
      done < <(split_csv "$req")
    done
  done

  # Apply --skip after dependency expansion. A skipped component still has its
  # dependents skipped only if the user listed them too; otherwise we error so
  # the user is forced to acknowledge the inconsistency.
  if [ -n "$SKIP" ]; then
    local -a skip_list=()
    while IFS= read -r n; do [ -n "$n" ] && skip_list+=("$n"); done < <(split_csv "$SKIP")
    local -a filtered=()
    for name in "${wanted[@]}"; do
      if contains "$name" "${skip_list[@]}"; then continue; fi
      # If this component requires a skipped one, fail loudly.
      local req="${REQUIRES_BY_NAME[$name]:-}"
      while IFS= read -r dep; do
        [ -n "$dep" ] || continue
        if contains "$dep" "${skip_list[@]}"; then
          fail "Cannot --skip '$dep': component '$name' requires it. Skip '$name' too or drop '$dep' from --skip."
        fi
      done < <(split_csv "$req")
      filtered+=("$name")
    done
    wanted=("${filtered[@]}")
  fi

  # Re-emit in canonical prefix order.
  PLAN=()
  for name in "${ORDER[@]}"; do
    if contains "$name" "${wanted[@]}"; then PLAN+=("$name"); fi
  done
}

# ---------------------------- Plan execution -------------------------------
run_component() {
  local name="$1"
  local file="${FILE_BY_NAME[$name]}"
  printf '\n--- %s ---\n' "$name"
  # shellcheck disable=SC1090
  source "$file"
  if declare -f run >/dev/null; then run; else fail "Component '$name' defines no run() function"; fi
  if declare -f verify >/dev/null; then verify; fi
  unset -f run verify || true
}

# ------------------------------- Main --------------------------------------
if [ "$DO_VALIDATE" = true ]; then validate_components; exit 0; fi
if [ "$DO_LIST" = true ]; then list_components; exit 0; fi

resolve_plan

if [ "${#PLAN[@]}" -eq 0 ]; then
  warn "Plan is empty (after --only/--skip resolution). Nothing to do."
  exit 0
fi

printf 'Plan: %s\n' "${PLAN[*]}"
if [ "$DRY_RUN" = true ]; then exit 0; fi

printf 'eip-hermes installer\n'
for name in "${PLAN[@]}"; do
  run_component "$name"
done

success "Hermes installer complete"
cat <<EOF

Next steps:
  hermes                                                   # start a session
  hermes memory status                                     # confirm Honcho is wired
  curl http://${HERMES_API_HOST}:${HERMES_API_PORT}/health
  curl http://${HERMES_DASHBOARD_HOST}:${HERMES_DASHBOARD_PORT}/api/status
  curl ${HONCHO_BASE_URL}/health
EOF
