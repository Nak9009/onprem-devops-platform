#!/usr/bin/env bash
# scripts/gitops-rollback.sh
# Performs a declarative Git-based rollback of an application overlay in the GitOps repository,
# preserving Git as the single source of truth (never mutating cluster state out-of-band).
#
# Usage:
#   ./scripts/gitops-rollback.sh --app api --env production [--to-tag 1.0.0-a1b2c3d4 | --revert-last] [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

APP_NAME="api"
TARGET_ENV="production"
TARGET_TAG=""
REVERT_LAST=false
DRY_RUN=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  -a, --app <name>       Application name under gitops/applications/ (default: api)
  -e, --env <overlay>    Environment overlay: dev, staging, production (default: production)
  -t, --to-tag <tag>     Roll back kustomization.yaml to a specific immutable image tag
  -r, --revert-last      Revert the most recent Git commit touching the target overlay
  -d, --dry-run          Preview the rollback change without modifying or committing files
  -h, --help             Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -a|--app)
      APP_NAME="$2"
      shift 2
      ;;
    -e|--env)
      TARGET_ENV="$2"
      shift 2
      ;;
    -t|--to-tag)
      TARGET_TAG="$2"
      shift 2
      ;;
    -r|--revert-last)
      REVERT_LAST=true
      shift
      ;;
    -d|--dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[ERROR] Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

OVERLAY_DIR="${PROJECT_ROOT}/gitops/applications/${APP_NAME}/overlays/${TARGET_ENV}"
KUSTOMIZATION_FILE="${OVERLAY_DIR}/kustomization.yaml"

if [[ ! -f "${KUSTOMIZATION_FILE}" ]]; then
  echo "[ERROR] Kustomization file not found: ${KUSTOMIZATION_FILE}" >&2
  exit 1
fi

if [[ "${TARGET_TAG}" == "latest" ]]; then
  echo "[ERROR] Rolling back to mutable 'latest' tag is forbidden by security policy." >&2
  exit 1
fi

CURRENT_TAG="$(awk -F'"' '/newTag:/ {print $2}' "${KUSTOMIZATION_FILE}")"

echo "======================================================================"
echo " GitOps Declarative Rollback Utility"
echo " Application      : ${APP_NAME}"
echo " Environment      : ${TARGET_ENV}"
echo " Overlay Path     : ${OVERLAY_DIR}"
echo " Current Image Tag: ${CURRENT_TAG}"
echo "======================================================================"

if [[ -n "${TARGET_TAG}" ]]; then
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[DRY-RUN] Would update newTag in ${KUSTOMIZATION_FILE} from '${CURRENT_TAG}' to '${TARGET_TAG}'"
    exit 0
  fi

  sed -i.bak -E "s|(newTag:[[:space:]]*).*|\1\"${TARGET_TAG}\"|g" "${KUSTOMIZATION_FILE}"
  rm -f "${KUSTOMIZATION_FILE}.bak"
  echo "[OK] Updated ${KUSTOMIZATION_FILE} to immutable tag '${TARGET_TAG}'."
  echo ""
  echo "Next steps to complete GitOps rollback:"
  echo "  1. Commit and push: git add ${KUSTOMIZATION_FILE} && git commit -m \"revert(${APP_NAME}/${TARGET_ENV}): rollback to ${TARGET_TAG}\" && git push"
  if [[ "${TARGET_ENV}" == "production" ]]; then
    echo "  2. Approve production sync in Argo CD: argocd app sync ${APP_NAME}-production"
  else
    echo "  2. Argo CD will automatically synchronize ${APP_NAME}-${TARGET_ENV}."
  fi
elif [[ "${REVERT_LAST}" == "true" ]]; then
  LAST_COMMIT="$(git -C "${PROJECT_ROOT}" log -n 1 --pretty=format:%H -- "${KUSTOMIZATION_FILE}" || true)"
  if [[ -z "${LAST_COMMIT}" ]]; then
    echo "[WARN] No Git commit history found yet for ${KUSTOMIZATION_FILE}."
    exit 0
  fi
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[DRY-RUN] Would execute: git revert --no-edit ${LAST_COMMIT}"
    exit 0
  fi
  git -C "${PROJECT_ROOT}" revert --no-edit "${LAST_COMMIT}"
  echo "[OK] Reverted commit ${LAST_COMMIT}."
else
  echo "[INFO] Specify --to-tag <immutable-tag> or --revert-last to perform a rollback."
  exit 1
fi

