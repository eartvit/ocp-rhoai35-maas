#!/usr/bin/env bash
# One-time reset of the failed, DIRECT NooBaa deployment from the Oct-2026
# RHOAI 3.5.1 lab installer. NOT for clusters with a working MCG / ODF setup.
#   ./cleanup-noobaa.sh --check
#   ./cleanup-noobaa.sh --apply --confirm-noobaa-data-loss
# Retains ODF/NooBaa operators and other already-installed operators.
set -Eeuo pipefail
NS=openshift-storage
MODE=check
CONFIRM=false
for arg in "$@"; do
  case "$arg" in
    --check) MODE=check ;;
    --apply) MODE=apply ;;
    --confirm-noobaa-data-loss) CONFIRM=true ;;
    *) echo "Usage: $0 [--check|--apply --confirm-noobaa-data-loss]" >&2; exit 2 ;;
  esac
done
say()  { printf '[cleanup] %s\n' "$*"; }
fail() { printf '[cleanup] ERROR: %s\n' "$*" >&2; exit 1; }
command -v oc >/dev/null || fail 'Missing oc'
command -v python3 >/dev/null || fail 'Missing python3'
oc whoami >/dev/null 2>&1 || fail 'Authenticate with oc first'
[[ "$(oc auth can-i '*' '*' --all-namespaces)" == yes ]] || fail 'Cluster-admin access required'
[[ "$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.type}')" == AWS ]] || fail 'AWS cluster expected'

# Do not run if ODF has already adopted the installation or manages storage.
if [[ -n "$(oc get storagecluster -n "$NS" -o name 2>/dev/null)" ]]; then
  fail 'A StorageCluster exists: cleanup is unsafe and not intended for a managed MCG deployment.'
fi
# Must be a truly unused lab object store. Do not erase customers/users' data.
for crd in objectbucketclaims.objectbucket.io objectbuckets.objectbucket.io; do
  if oc get crd "$crd" >/dev/null 2>&1; then
    plural="${crd%%.*}"
    if [[ "$plural" == objectbucketclaims ]]; then objects="$(oc get "$plural" -A -o name)";
    else objects="$(oc get "$plural" -o name)"; fi
    [[ -z "$objects" ]] || fail "Existing $plural detected ($objects); refusing data loss."
  fi
done
for resource in backingstores.noobaa.io bucketclasses.noobaa.io namespacestores.noobaa.io; do
  if ! oc get crd "$resource" >/dev/null 2>&1; then continue; fi
  entries="$(oc get "$resource" -n "$NS" -o json | RESOURCE="$resource" python3 -c '
import json,os,sys
allowed={"backingstores.noobaa.io":{"noobaa-default-backing-store"},
         "bucketclasses.noobaa.io":{"noobaa-default-bucket-class"},
         "namespacestores.noobaa.io":set()}[os.environ["RESOURCE"]]
print(" ".join(x["metadata"]["name"] for x in json.load(sys.stdin).get("items",[])
               if x["metadata"]["name"] not in allowed))')"
  [[ -z "$entries" ]] || fail "Non-default $resource detected ($entries); refusing data loss."
done

if ! oc get noobaa noobaa -n "$NS" >/dev/null 2>&1; then
  say 'No NooBaa custom resource exists. Nothing to reset automatically.'
  exit 0
fi
phase="$(oc get noobaa noobaa -n "$NS" -o jsonpath='{.status.phase}')"
uid="$(oc get noobaa noobaa -n "$NS" -o jsonpath='{.metadata.uid}')"
[[ "$phase" == Configuring || "$phase" == Creating || "$phase" == Error ]] || fail "NooBaa phase '$phase' is outside expected failed-install states; refusing deletion."
say "NooBaa $NS/noobaa: UID=$uid, phase=$phase"
say 'No StorageCluster or OBC/ObjectBucket detected; no non-default backing stores/classes detected.'
say 'Will remove only the DIRECT NooBaa installation and its operator-owned resources.'
say 'Will leave the ODF Operator, namespace, unrelated workloads and other Operators installed.'
say 'A bound NooBaa database PVC may be deleted (irreversible data loss) if still present and confirmed operator-owned.'
[[ "$MODE" == apply ]] || { say 'Read-only check passed. Run --apply --confirm-noobaa-data-loss to proceed.'; exit 0; }
[[ "$CONFIRM" == true ]] || fail 'For destructive cleanup, add --confirm-noobaa-data-loss'

# Guard specifically for this failed direct deployment. Never remove finalizers
# automatically; if normal reconciliation fails, stop and inspect.
oc patch noobaa noobaa -n "$NS" --type=merge \
  -p '{"spec":{"cleanupPolicy":{"allowNoobaaDeletion":true}}}'
oc delete noobaa noobaa -n "$NS" --wait=false
if ! oc wait --for=delete noobaa/noobaa -n "$NS" --timeout=300s; then
  fail 'NooBaa graceful deletion did not finish. Inspect operator logs/finalizers; no force-deletion was performed.'
fi
say 'NooBaa CR removed.'

# Normally operator garbage collection removes this PVC. If it remains, only
# delete when ownership to THIS NooBaa CR is positively established by UID.
PVC=db-noobaa-db-pg-0
if oc get pvc "$PVC" -n "$NS" >/dev/null 2>&1; then
  if ! oc get pvc "$PVC" -n "$NS" -o json | EXPECTED_UID="$uid" python3 -c '
import json,os,sys
j=json.load(sys.stdin)
refs=j.get("metadata",{}).get("ownerReferences",[])
sys.exit(0 if any(x.get("uid")==os.environ["EXPECTED_UID"] and x.get("kind")=="NooBaa" for x in refs) else 1)'; then
    fail "PVC $NS/$PVC remains without a verified NooBaa owner UID. Not deleting; inspect it manually."
  fi
  say "Deleting operator-owned PVC $NS/$PVC (its PV may be reclaimed/deleted by the StorageClass)."
  oc delete pvc "$PVC" -n "$NS" --wait=true --timeout=180s
fi

# The original failed script created this StorageClass manually. Only delete it
# if no ObjectBucketClaims/Objects existed (verified above) and provisioner fits.
SC=openshift-storage.noobaa.io
if oc get storageclass "$SC" >/dev/null 2>&1; then
  provisioner="$(oc get storageclass "$SC" -o jsonpath='{.provisioner}')"
  [[ "$provisioner" == openshift-storage.noobaa.io/obc ]] || fail "Unexpected provisioner for $SC: $provisioner"
  say "Deleting stale $SC StorageClass; the ODF deployment should reconcile it."
  oc delete storageclass "$SC"
fi
say 'Cleanup complete. Run setup-cluster.sh --check (updated version) before --apply.'
