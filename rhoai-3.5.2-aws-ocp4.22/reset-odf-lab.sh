#!/usr/bin/env bash
# Disposable AWS OpenShift 4.21/4.22 lab only.
# Removes the ODF/NooBaa deployment AND the openshift-storage namespace,
# including the namespace-scoped NooBaa/ODF Operators, CSVs and Subscriptions.
# It deliberately preserves cluster-scoped CRDs: OLM may reuse them on reinstall.
# Usage: ./reset-odf-lab.sh --check
#        ./reset-odf-lab.sh --apply --confirm-destroy-odf
set -Eeuo pipefail
NS=openshift-storage
MODE=check
CONFIRMED=false
for arg in "$@"; do
  case "$arg" in
    --check) MODE=check ;;
    --apply) MODE=apply ;;
    --confirm-destroy-odf) CONFIRMED=true ;;
    *) printf 'Usage: %s [--check|--apply --confirm-destroy-odf]\n' "$0" >&2; exit 2 ;;
  esac
done
say() { printf '[reset-odf] %s\n' "$*"; }
die() { printf '[reset-odf] ERROR: %s\n' "$*" >&2; exit 1; }
command -v oc >/dev/null || die 'oc CLI not installed'
command -v python3 >/dev/null || die 'python3 not installed'
oc whoami >/dev/null 2>&1 || die 'Authenticate with oc first'
[[ "$(oc auth can-i '*' '*' --all-namespaces)" == yes ]] || die 'cluster-admin access required'
[[ "$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.type}')" == AWS ]] || die 'This reset is intended for AWS only'
ocp_version="$(oc get clusterversion version -o jsonpath='{.status.desired.version}')"
[[ "$ocp_version" == 4.21.* || "$ocp_version" == 4.22.* ]] || die "This destructive lab reset is only approved for OpenShift 4.21 or 4.22 (found $ocp_version)"

# All cluster-scoped OBCs and namespaced OBCs must be absent. These represent
# customer data and must never be destroyed by a generic test reset.
for crd in objectbucketclaims.objectbucket.io objectbuckets.objectbucket.io; do
  if oc get crd "$crd" >/dev/null 2>&1; then
    if [[ "$crd" == objectbucketclaims.* ]]; then
      entries="$(oc get objectbucketclaims.objectbucket.io -A -o name)"
    else
      entries="$(oc get objectbuckets.objectbucket.io -o name)"
    fi
    [[ -z "$entries" ]] || die "$crd has existing entries: $entries"
  fi
done

# For a genuine lab-only MCG reset, do not touch a Ceph-based ODF system.
if oc get namespace "$NS" >/dev/null 2>&1; then
  storageclusters="$(oc get storageclusters.ocs.openshift.io -n "$NS" -o json 2>/dev/null || :)"
  if [[ -n "$storageclusters" ]]; then
    printf '%s\n' "$storageclusters" | python3 -c '
import json,sys
items=json.load(sys.stdin).get("items",[])
for x in items:
    n=x["metadata"]["name"]
    m=x.get("spec",{}).get("multiCloudGateway",{})
    if n!="ocs-storagecluster" or m.get("reconcileStrategy")!="standalone":
        print("Refusing non-standalone or unexpected StorageCluster: "+n,file=sys.stderr)
        sys.exit(1)
' || die 'Cannot reset this StorageCluster safely'
  fi
  # This utility is intentionally a namespace-wide reset. The explicit
  # --confirm-destroy-odf flag authorizes deletion of ALL resources inside
  # openshift-storage, including any unexpected subscriptions and PVCs.
  # Do not use it on a shared storage namespace.
  say 'Destruction scope includes EVERY resource in openshift-storage, even unexpected Operators and PVCs.'

fi

if oc get storageclass openshift-storage.noobaa.io >/dev/null 2>&1; then
  p="$(oc get storageclass openshift-storage.noobaa.io -o jsonpath='{.provisioner}')"
  [[ "$p" == openshift-storage.noobaa.io/obc ]] || die "Unexpected bucket StorageClass provisioner: $p"
fi

say 'Preflight passed: no ObjectBucketClaim/ObjectBucket resources elsewhere in the cluster; namespace-scoped resources are intentionally not allowlisted.'
say 'Scope: standalone MCG/NooBaa, ALL resources in openshift-storage (including any subscriptions and PVCs), and the NooBaa ObjectBucket StorageClass.'
say 'Preserved: all other namespaces, RHOAI, Keycloak, cert-manager, AWS cluster nodes, and cluster-scoped CRDs.'
say 'Warning: AWS S3 buckets/IAM roles outside OpenShift may require separate cloud-resource cleanup.'
if [[ "$MODE" == check ]]; then
  say 'Read-only; no changes made. To destroy, add --apply --confirm-destroy-odf.'
  exit 0
fi
[[ "$CONFIRMED" == true ]] || die 'Destructive operation requires --confirm-destroy-odf'

if oc get namespace "$NS" >/dev/null 2>&1; then
  # If an ODF StorageSystem exists, ask the ODF operators to reconcile removal
  # while they still exist. A bare direct NooBaa deployment has no StorageSystem.
  if oc get crd storagesystems.odf.openshift.io >/dev/null 2>&1; then
    if [[ -n "$(oc get storagesystems.odf.openshift.io -n "$NS" -o name)" ]]; then
      say 'Deleting StorageSystem through the ODF operator...'
      oc delete storagesystems.odf.openshift.io -n "$NS" --all --wait=true --timeout=900s
    fi
  fi
  if oc get crd storageclusters.ocs.openshift.io >/dev/null 2>&1; then
    if oc get storagecluster ocs-storagecluster -n "$NS" >/dev/null 2>&1; then
      say 'Deleting standalone StorageCluster...'
      oc delete storagecluster ocs-storagecluster -n "$NS" --wait=true --timeout=900s
    fi
  fi
  if oc get crd noobaas.noobaa.io >/dev/null 2>&1 && oc get noobaa noobaa -n "$NS" >/dev/null 2>&1; then
    say 'Deleting remaining NooBaa system and its database...'
    oc patch noobaa noobaa -n "$NS" --type=merge -p '{"spec":{"cleanupPolicy":{"allowNoobaaDeletion":true}}}'
    oc delete noobaa noobaa -n "$NS" --wait=true --timeout=900s
  fi
  say 'Deleting openshift-storage namespace and its ODF/NooBaa Operators...'
  oc project default >/dev/null
  oc delete namespace "$NS" --wait=true --timeout=900s
else
  say 'openshift-storage namespace is already absent.'
fi
if oc get storageclass openshift-storage.noobaa.io >/dev/null 2>&1; then
  say 'Deleting leftover NooBaa ObjectBucket StorageClass...'
  oc delete storageclass openshift-storage.noobaa.io --wait=true --timeout=120s
fi
say 'Reset complete. ODF and NooBaa operator pods/subscriptions in openshift-storage are gone.'
say 'Run: ./setup-cluster.sh --check && ./setup-cluster.sh --apply'
