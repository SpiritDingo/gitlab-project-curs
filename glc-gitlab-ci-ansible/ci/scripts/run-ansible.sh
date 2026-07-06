#!/usr/bin/env bash
# Unified Ansible runner for GitLab CI (shell and docker executors).
set -euo pipefail

PROJECT_DIR="${CI_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
LOG_DIR="${PROJECT_DIR}/logs"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
PIPELINE_ID="${CI_PIPELINE_ID:-local}"
JOB_NAME="${CI_JOB_NAME:-manual}"
LOG_FILE="${LOG_DIR}/${PIPELINE_ID}_${JOB_NAME}_${TIMESTAMP}.log"
TEMP_PLAYBOOK=""
VAULT_PASS_FILE=""

cleanup() {
  if [[ -n "${TEMP_PLAYBOOK}" && -f "${TEMP_PLAYBOOK}" ]]; then
    rm -f "${TEMP_PLAYBOOK}"
  fi
  if [[ -n "${VAULT_PASS_FILE}" && -f "${VAULT_PASS_FILE}" ]]; then
    rm -f "${VAULT_PASS_FILE}"
  fi
}
trap cleanup EXIT

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${LOG_FILE}"
}

write_log_header() {
  mkdir -p "${LOG_DIR}"
  {
    echo "========================================"
    echo "Ansible CI Run Log"
    echo "========================================"
    echo "Timestamp   : $(date -Iseconds)"
    echo "Pipeline ID : ${PIPELINE_ID}"
    echo "Job Name    : ${JOB_NAME}"
    echo "Project     : ${CI_PROJECT_NAME:-local}"
    echo "Branch/Ref  : ${CI_COMMIT_REF_NAME:-local}"
    echo "Commit      : ${CI_COMMIT_SHA:-local}"
    echo "Executor    : ${EXECUTOR:-shell}"
    echo "Inventory   : ${INVENTORY:-not-set}"
    echo "Playbook    : ${PLAYBOOK:-not-set}"
    echo "Role        : ${ROLE:-not-set}"
    echo "Tags        : ${TAGS:-}"
    echo "Skip Tags   : ${SKIP_TAGS:-}"
    echo "Limit       : ${LIMIT:-}"
    echo "Check Mode  : ${CHECK_MODE:-false}"
    echo "Extra Vars  : ${EXTRA_VARS:-}"
    echo "========================================"
    echo
  } > "${LOG_FILE}"
}

resolve_inventory() {
  local inventory="${INVENTORY:-}"
  if [[ -z "${inventory}" ]]; then
    log "ERROR: INVENTORY variable is not set"
    exit 1
  fi

  local inventory_base="${PROJECT_DIR}/inventories/${inventory}"
  if [[ -f "${inventory_base}/hosts.yml" ]]; then
    echo "${inventory_base}/hosts.yml"
  elif [[ -f "${inventory_base}/hosts.ini" ]]; then
    echo "${inventory_base}/hosts.ini"
  elif [[ -f "${inventory_base}" ]]; then
    echo "${inventory_base}"
  else
    log "ERROR: Inventory not found for '${inventory}'"
    log "Expected: ${inventory_base}/hosts.yml or hosts.ini"
    exit 1
  fi
}

prepare_vault() {
  if [[ -n "${ANSIBLE_VAULT_PASSWORD:-}" ]]; then
    VAULT_PASS_FILE="$(mktemp)"
    chmod 600 "${VAULT_PASS_FILE}"
    printf '%s' "${ANSIBLE_VAULT_PASSWORD}" > "${VAULT_PASS_FILE}"
    log "Vault password file prepared"
  fi
}

install_dependencies() {
  cd "${PROJECT_DIR}"
  if [[ -f requirements.yml ]]; then
    log "Installing Ansible Galaxy dependencies..."
    ansible-galaxy collection install -r requirements.yml 2>&1 | tee -a "${LOG_FILE}" || true
  fi
}

prepare() {
  write_log_header
  cd "${PROJECT_DIR}"
  log "Working directory: ${PROJECT_DIR}"
  log "Ansible version:"
  ansible --version 2>&1 | tee -a "${LOG_FILE}"
  install_dependencies
  prepare_vault

  local inventory_file
  inventory_file="$(resolve_inventory)"
  log "Validating inventory: ${inventory_file}"
  ansible-inventory -i "${inventory_file}" --graph 2>&1 | tee -a "${LOG_FILE}"
}

build_ansible_command() {
  local inventory_file playbook_file
  inventory_file="$(resolve_inventory)"

  if [[ -n "${ROLE:-}" ]]; then
    TEMP_PLAYBOOK="$(mktemp /tmp/ansible-role-XXXXXX.yml)"
    cat > "${TEMP_PLAYBOOK}" <<EOF
---
- name: Run role ${ROLE}
  hosts: all
  gather_facts: true
  roles:
    - ${ROLE}
EOF
    playbook_file="${TEMP_PLAYBOOK}"
    log "Generated temporary playbook for role: ${ROLE}"
  elif [[ -n "${PLAYBOOK:-}" ]]; then
    if [[ ! -f "${PROJECT_DIR}/${PLAYBOOK}" && ! -f "${PLAYBOOK}" ]]; then
      log "ERROR: Playbook not found: ${PLAYBOOK}"
      exit 1
    fi
    if [[ -f "${PROJECT_DIR}/${PLAYBOOK}" ]]; then
      playbook_file="${PROJECT_DIR}/${PLAYBOOK}"
    else
      playbook_file="${PLAYBOOK}"
    fi
  else
    log "ERROR: Either PLAYBOOK or ROLE must be specified"
    exit 1
  fi

  local cmd=(ansible-playbook -i "${inventory_file}" "${playbook_file}")

  if [[ -n "${TAGS:-}" ]]; then
    cmd+=(--tags "${TAGS}")
  fi
  if [[ -n "${SKIP_TAGS:-}" ]]; then
    cmd+=(--skip-tags "${SKIP_TAGS}")
  fi
  if [[ -n "${LIMIT:-}" ]]; then
    cmd+=(--limit "${LIMIT}")
  fi
  if [[ "${CHECK_MODE:-false}" == "true" ]]; then
    cmd+=(--check)
  fi
  if [[ "${DIFF_MODE:-false}" == "true" ]]; then
    cmd+=(--diff)
  fi
  if [[ -n "${EXTRA_VARS:-}" ]]; then
    cmd+=(--extra-vars "${EXTRA_VARS}")
  fi
  if [[ -n "${VAULT_PASS_FILE}" ]]; then
    cmd+=(--vault-password-file "${VAULT_PASS_FILE}")
  fi
  if [[ -n "${VERBOSITY:-}" ]]; then
    local verbose_flag="-"
    local i
    for ((i = 0; i < ${#VERBOSITY}; i++)); do
      verbose_flag+="v"
    done
    cmd+=("${verbose_flag}")
  fi

  printf '%s\n' "${cmd[@]}"
}

run() {
  if [[ ! -f "${LOG_FILE}" ]]; then
    write_log_header
    prepare_vault
  fi

  cd "${PROJECT_DIR}"
  local cmd
  cmd="$(build_ansible_command)"
  log "Executing: ${cmd}"

  local exit_code=0
  # shellcheck disable=SC2086
  eval "${cmd}" 2>&1 | tee -a "${LOG_FILE}" || exit_code=$?

  {
    echo
    echo "========================================"
    echo "Run finished with exit code: ${exit_code}"
    echo "Log file: ${LOG_FILE}"
    echo "========================================"
  } | tee -a "${LOG_FILE}"

  exit "${exit_code}"
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [--prepare|--run|--help]

Environment variables:
  PLAYBOOK          Path to playbook (relative to project root)
  ROLE              Role name (generates temporary playbook)
  INVENTORY         Inventory project name (e.g. project-web)
  TAGS              Comma-separated tags
  SKIP_TAGS         Comma-separated skip tags
  LIMIT             Host limit pattern
  EXTRA_VARS        Extra variables (JSON or key=value)
  CHECK_MODE        true/false — dry-run mode
  DIFF_MODE         true/false — show diffs
  VERBOSITY         v, vv, vvv, vvvv
  ANSIBLE_VAULT_PASSWORD  Vault password (from CI variable)
EOF
}

case "${1:-}" in
  --prepare)
    prepare
    ;;
  --run)
    run
    ;;
  --help|-h)
    usage
    ;;
  *)
    usage
    exit 1
    ;;
esac
