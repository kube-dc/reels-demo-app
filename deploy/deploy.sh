#!/usr/bin/env bash
# Deploy the app to a kube-dc project and print its HTTPS URL.
#
#   deploy/deploy.sh <namespace> <app> <image>
#
# Uses the current kubectl context (CI writes one with a short-lived token).
# Optional: DB_SECRET (default <app>-db-owner), PULL_USER + PULL_TOKEN to
# create/refresh the <app>-pull image pull Secret for a private registry,
# PULL_SECRET (the pull Secret the app uses, default <app>-pull; for a kube-dc
# managed registry its platform Secret kdc-registry-<registry>),
# TIMEOUT (rollout, hostname and URL wait, default 300s), HEALTH_PATH
# (checked on the live URL, default /), PORT (container port, default 8080), and for a preview
# PREVIEW_HOURS (kube-dc removes it that long after the last deploy),
# PREVIEW_REPOSITORY + PREVIEW_PULL_REQUEST (and when that pull request
# closes; public repositories), and PREVIEW_DATABASE: a plan such as
# postgresql-development for a fresh, empty database of the preview's own
# (<app>-db, removed with the preview; the app gets <app>-db-owner), or
# PREVIEW_DATABASE_FROM: a managed service in the same project whose latest
# backup is restored into <app>-db (a copy of its data, minutes). With
# PREVIEW_DATABASE_MODE=branch the copy is a branch of the live service (an
# online snapshot, about two minutes) instead; a source that cannot branch
# falls back to the latest backup. A copy names a ServiceCopyGrant with
# PREVIEW_DATABASE_GRANT and the app it grants with PREVIEW_OF; copies made
# by a CI machine identity must (a grant with masking masks every copy).
set -euo pipefail

NAMESPACE="$1" APP="$2" IMAGE="$3"
PORT="${PORT:-8080}" DB_SECRET="${DB_SECRET:-$APP-db-owner}" PULL_SECRET="${PULL_SECRET:-$APP-pull}"
TIMEOUT="${TIMEOUT:-300}"
cd "$(dirname "$0")"

if [ -n "${PREVIEW_DATABASE:-}" ] || [ -n "${PREVIEW_DATABASE_FROM:-}" ]; then
  # The preview's own database, labelled like the rest of it so it goes when
  # the preview goes; Delete frees its data and capacity. Either a fresh,
  # empty one (PREVIEW_DATABASE: a plan) or a copy of an existing service's
  # latest backup (PREVIEW_DATABASE_FROM: its name, in this same project).
  db="$APP-db"
  label="${PREVIEW_HOURS:+preview.kube-dc.com/name: $APP}"
  # A copy names the grant that allows it and the app the grant names; the
  # platform refuses a CI identity's copy without them and masks the copy
  # when the grant says so.
  oplabel="$label" grantmeta=""
  if [ -n "${PREVIEW_DATABASE_GRANT:-}" ]; then
    grantmeta="annotations: { services.kube-dc.com/copy-grant: $PREVIEW_DATABASE_GRANT }"
    oplabel="${label:+$label, }build.kube-dc.com/preview-of: ${PREVIEW_OF:?PREVIEW_OF (the app the grant names) is needed with PREVIEW_DATABASE_GRANT}"
  fi
  if [ -n "${PREVIEW_DATABASE_FROM:-}" ]; then
    src=$(kubectl -n "$NAMESPACE" get managedservice "$PREVIEW_DATABASE_FROM" -o json 2>/dev/null) || {
      echo "No managed service $PREVIEW_DATABASE_FROM in $NAMESPACE: a copy is restored into the source's project, so previews must deploy there."; exit 1; }
    # The copy runs the source's version: its spec, else the version the hub resolved, else its running image's tag.
    target=$(jq -c --arg db "$db" '{name: $db, planRef: {name: .spec.planRef.name},
      engineVersion: ([.spec.engineVersion, .status.resolvedSpec.engineVersion, ((.status.engineDetails.imageName // "") | if . == "" then "" else (split("@")[0] | split(":") | last) end)] | map(select(. != null and . != "")) | first // ""),
      placement: .spec.placement, connectivity: .spec.connectivity, parameters: (.spec.parameters // {})}' <<<"$src")
    if ! kubectl -n "$NAMESPACE" get managedservice "$db" >/dev/null 2>&1; then
      copied=""
      if [ "${PREVIEW_DATABASE_MODE:-restore}" = branch ]; then
        kubectl -n "$NAMESPACE" apply -f - <<MANIFEST
apiVersion: services.kube-dc.com/v1alpha1
kind: ServiceOperation
metadata:
  name: $db-branch
  labels: { $oplabel }
  $grantmeta
spec:
  type: BranchToNew
  serviceRef: { name: $PREVIEW_DATABASE_FROM }
  serviceUID: $(jq -r .metadata.uid <<<"$src")
  idempotencyKey: $db-branch-$(jq -r .metadata.uid <<<"$src")
  branch:
    target: $target
MANIFEST
        echo "Branching $PREVIEW_DATABASE_FROM into $db..."
        for _ in $(seq 1 60); do
          kubectl -n "$NAMESPACE" get managedservice "$db" >/dev/null 2>&1 && { copied=branch; break; }
          phase=$(kubectl -n "$NAMESPACE" get serviceoperation "$db-branch" -o jsonpath='{.status.phase}' 2>/dev/null || true)
          case "$phase" in
            Rejected|Failed|Cancelled)
              echo "The branch was refused: $(kubectl -n "$NAMESPACE" get serviceoperation "$db-branch" -o jsonpath='{.status.message}')"
              echo "Restoring the latest backup instead."
              break ;;
          esac
          sleep 5
        done
      fi
      if [ -z "$copied" ]; then
        # Platform-internal records (a branch's snapshot) are never a restore base.
        backup=$(kubectl -n "$NAMESPACE" get servicebackups -o json | jq -c --arg s "$PREVIEW_DATABASE_FROM" \
          '[.items[] | select(.spec.serviceRef.name == $s and .status.backup.phase == "Completed" and ((.metadata.labels // {})["services.kube-dc.com/internal"] // "") == "")] | sort_by(.status.backup.completedAt) | last // empty')
        [ -n "$backup" ] || { echo "$PREVIEW_DATABASE_FROM has no completed backup to copy yet."; exit 1; }
        kubectl -n "$NAMESPACE" apply -f - <<MANIFEST
apiVersion: services.kube-dc.com/v1alpha1
kind: ServiceOperation
metadata:
  name: $db-copy
  labels: { $oplabel }
  $grantmeta
spec:
  type: RestoreToNew
  serviceRef: { name: $PREVIEW_DATABASE_FROM }
  serviceUID: $(jq -r .metadata.uid <<<"$src")
  idempotencyKey: $db-copy-$(jq -r .metadata.uid <<<"$backup")
  restore:
    backupRef: { name: $(jq -r .metadata.name <<<"$backup"), uid: $(jq -r .metadata.uid <<<"$backup") }
    target: $target
MANIFEST
        echo "Restoring $PREVIEW_DATABASE_FROM's backup of $(jq -r .status.backup.completedAt <<<"$backup") into $db..."
        for _ in $(seq 1 60); do kubectl -n "$NAMESPACE" get managedservice "$db" >/dev/null 2>&1 && break; sleep 5; done
      fi
    fi
    # A restored service is born Retain; a preview's copy is disposable.
    kubectl -n "$NAMESPACE" patch managedservice "$db" --type merge \
      -p "{\"metadata\":{\"labels\":{${PREVIEW_HOURS:+\"preview.kube-dc.com/name\":\"$APP\"}}},\"spec\":{\"deletionPolicy\":\"Delete\"}}"
  else
    kubectl -n "$NAMESPACE" apply -f - <<MANIFEST
apiVersion: services.kube-dc.com/v1alpha1
kind: ManagedService
metadata:
  name: $db
  labels: { $label }
spec:
  classRef: { name: ${PREVIEW_DATABASE%%-*} }
  planRef: { name: $PREVIEW_DATABASE }
  placement: { mode: ProviderShared }
  connectivity: { classRef: { name: tenant-native } }
  topology: { instances: 1 }
  deletionPolicy: Delete
MANIFEST
  fi
  uid=$(kubectl -n "$NAMESPACE" get managedservice "$db" -o jsonpath='{.metadata.uid}')
  # A binding left from an earlier copy of the same name points at a service
  # that is gone (its serviceUID cannot change): replace it.
  bound=$(kubectl -n "$NAMESPACE" get servicebinding "$db-owner" -o jsonpath='{.spec.serviceUID}' 2>/dev/null || true)
  if [ -n "$bound" ] && [ "$bound" != "$uid" ]; then
    kubectl -n "$NAMESPACE" delete servicebinding "$db-owner" --wait=true
  fi
  kubectl -n "$NAMESPACE" apply -f - <<MANIFEST
apiVersion: services.kube-dc.com/v1alpha1
kind: ServiceBinding
metadata:
  name: $db-owner
  labels: { $label }
spec:
  serviceRef: { name: $db }
  serviceUID: $uid
  role: owner
  consumer: { kind: Namespace, name: $NAMESPACE, namespace: $NAMESPACE }
  delivery: { mode: DataPlaneLocalSecret, secretName: $db-owner }
MANIFEST
  DB_SECRET="$db-owner"
  # A new database takes a few minutes, a copy longer; the app starts once its credentials exist.
  echo "Waiting for the preview database $db..."
  for _ in $(seq 1 $((${DB_TIMEOUT:-900} / 10))); do
    kubectl -n "$NAMESPACE" get secret "$DB_SECRET" >/dev/null 2>&1 && break
    # A copy whose masking script failed stays closed: say why now.
    masking=$(kubectl -n "$NAMESPACE" get managedservice "$db" -o jsonpath='{.status.conditions[?(@.reason=="RestoreMaskingFailed")].message}' 2>/dev/null || true)
    if [ -n "$masking" ]; then
      echo "The masking script failed on the copy $db: $masking"
      echo "Fix the script, create a new grant for it, then delete $db and deploy again."
      exit 1
    fi
    sleep 10
  done
  if ! kubectl -n "$NAMESPACE" get secret "$DB_SECRET" >/dev/null 2>&1; then
    echo "The preview database $db is not ready:"
    kubectl -n "$NAMESPACE" get managedservice "$db" -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}'
    exit 1
  fi
fi

if [ -n "${PULL_TOKEN:-}" ]; then
  kubectl -n "$NAMESPACE" create secret docker-registry "$APP-pull" \
    --docker-server="${IMAGE%%/*}" --docker-username="${PULL_USER:?PULL_USER}" --docker-password="$PULL_TOKEN" \
    --dry-run=client -o yaml | kubectl -n "$NAMESPACE" apply -f -
fi

sed -e "s|\${APP}|$APP|g" -e "s|\${IMAGE}|$IMAGE|g" -e "s|\${PORT}|$PORT|g" -e "s|\${DB_SECRET}|$DB_SECRET|g" -e "s|\${PULL_SECRET}|$PULL_SECRET|g" app.yaml | kubectl -n "$NAMESPACE" apply -f -

if [ -n "${PREVIEW_HOURS:-}" ]; then
  # Every object of the preview carries its name; the Deployment, when and why it goes.
  kubectl -n "$NAMESPACE" label --overwrite deployment/"$APP" service/"$APP" preview.kube-dc.com/name="$APP" >/dev/null
  [ -n "${PULL_TOKEN:-}" ] && kubectl -n "$NAMESPACE" label --overwrite secret/"$APP-pull" preview.kube-dc.com/name="$APP" >/dev/null
  kubectl -n "$NAMESPACE" annotate --overwrite deployment/"$APP" \
    preview.kube-dc.com/expires-at="$(date -u -d "+${PREVIEW_HOURS} hours" +%Y-%m-%dT%H:%M:%SZ)" \
    ${PREVIEW_REPOSITORY:+preview.kube-dc.com/repository="$PREVIEW_REPOSITORY"} \
    ${PREVIEW_PULL_REQUEST:+preview.kube-dc.com/pull-request="$PREVIEW_PULL_REQUEST"} >/dev/null
fi

if ! kubectl -n "$NAMESPACE" rollout status "deployment/$APP" --timeout="${TIMEOUT}s"; then
  echo "Rollout failed. Recent events and logs:"
  kubectl -n "$NAMESPACE" get events --sort-by=.lastTimestamp | tail -15 || true
  kubectl -n "$NAMESPACE" logs "deployment/$APP" --tail=30 || true
  exit 1
fi

# The platform writes the hostname once the certificate is issued.
for _ in $(seq 1 $((TIMEOUT / 5))); do
  host=$(kubectl -n "$NAMESPACE" get service "$APP" -o jsonpath='{.metadata.annotations.service\.nlb\.kube-dc\.com/route-hostname-status}')
  [ -n "$host" ] && break
  sleep 5
done
if [ -z "$host" ]; then
  echo "The Service has no hostname yet; check: kubectl -n $NAMESPACE get events"
  exit 1
fi

# Green only when the live URL answers (certificate served, route programmed,
# app healthy), so the GitHub deployment shows what users get.
for _ in $(seq 1 $((TIMEOUT / 5))); do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$host${HEALTH_PATH:-/}" || true)
  if [ "$code" -ge 200 ] 2>/dev/null && [ "$code" -lt 400 ]; then
    echo "url=https://$host"
    [ -n "${GITHUB_OUTPUT:-}" ] && echo "url=https://$host" >> "$GITHUB_OUTPUT"
    exit 0
  fi
  sleep 5
done
echo "https://$host${HEALTH_PATH:-/} did not answer (last status: ${code:-none})."
kubectl -n "$NAMESPACE" logs "deployment/$APP" --tail=30 || true
exit 1
