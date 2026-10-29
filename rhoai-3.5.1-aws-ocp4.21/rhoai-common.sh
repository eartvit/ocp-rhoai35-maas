#!/usr/bin/env bash
# Shared functions for setup-cluster.sh and setup-maas.sh. Source; never execute.
set -Eeuo pipefail
log()  { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '[%s] WARNING: %s\n' "$(date '+%F %T')" "$*" >&2; }
die()  { printf '[%s] ERROR: %s\n' "$(date '+%F %T')" "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }
yes() { case "${1:-false}" in true|yes|1|TRUE) return 0;; *) return 1;; esac; }
require_numeric() { [[ "$2" =~ ^[0-9]+$ ]] || die "$1 must be a nonnegative integer, got '$2'"; }
ensure_ns() { oc get namespace "$1" >/dev/null 2>&1 || oc create namespace "$1"; }
wait_for() {
  local msg="$1" timeout="$2" interval="$3"; shift 3
  local start=$SECONDS
  until "$@" >/dev/null 2>&1; do
    if (( SECONDS-start >= timeout )); then die "Timeout: $msg. Inspect resources and rerun."; fi
    log "Waiting for $msg (${SECONDS} elapsed)"; sleep "$interval"
  done
  log "Ready: $msg"
}
check_crd() { oc get crd "$1" >/dev/null 2>&1; }
wait_crd() { wait_for "CRD $1" "${CRD_TIMEOUT:-900}" 15 check_crd "$1"; }
check_phase() { local ns=(); [[ -z "${3:-}" ]] || ns=(-n "$3"); [[ "$(oc get "$1" "$2" "${ns[@]}" -o jsonpath='{.status.phase}' 2>/dev/null || :)" == "$4" ]]; }
# Safely refuses to install into a namespace with an unexpected OperatorGroup.
ensure_group() {
  local ns="$1" name="$2" mode="$3" count
  [[ "$ns" == openshift-operators ]] && return 0
  ensure_ns "$ns"
  count="$(oc get operatorgroup -n "$ns" -o json | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("items",[])))')"
  if (( count > 0 )); then
    local existing
    existing="$(oc get operatorgroup -n "$ns" -o json | python3 -c 'import json,sys; o=json.load(sys.stdin)["items"]; print(",".join(x["metadata"]["name"] for x in o))')"
    warn "Reusing existing OperatorGroup(s) in $ns: $existing. Verify installation mode if installation fails."
    return
  fi
  if [[ "$mode" == own ]]; then
    cat <<YAML | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: $name
  namespace: $ns
spec:
  targetNamespaces:
  - $ns
YAML
  else
    cat <<YAML | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: $name
  namespace: $ns
YAML
  fi
}
# Resolve version-matched ODF channel from the live OpenShift version.
# A configured explicit override is allowed only if it matches the detected minor.
resolve_odf_channel() {
  local version minor expected configured="${ODF_CHANNEL:-auto}" catalog
  version="$(oc get clusterversion version -o jsonpath='{.status.desired.version}')" || die 'Unable to discover OpenShift version'
  [[ "$version" =~ ^4\.([0-9]+)\. ]] || die "Cannot derive ODF channel from OpenShift version '$version'"
  minor=$((10#${BASH_REMATCH[1]}))
  (( minor >= 21 )) || die "ODF automatic channel selection requires OCP 4.21+, found $version"
  expected="stable-4.$minor"
  if [[ -n "$configured" && "$configured" != auto && "$configured" != "$expected" ]]; then
    die "ODF_CHANNEL=$configured does not match OCP $version (expected $expected). Set ODF_CHANNEL=auto."
  fi
  # Read the actual catalog before any subscription is installed.
  catalog="$(oc get packagemanifest odf-operator -n openshift-marketplace -o json)" || die 'ODF package not found in OperatorHub catalog'
  printf '%s' "$catalog" | ODF_EXPECTED_CHANNEL="$expected" python3 -c '
import json,os,sys
obj=json.load(sys.stdin)
channels={c.get("name") for c in obj.get("status",{}).get("channels",[])}
wanted=os.environ["ODF_EXPECTED_CHANNEL"]
if wanted not in channels:
 print(f"ODF channel {wanted} not present in cluster catalog; available: {sorted(channels)}",file=sys.stderr)
 sys.exit(1)
' || die "ODF $expected unavailable; refusing to install an older release"
  ODF_CHANNEL="$expected"
  export ODF_CHANNEL
  log "Using ODF channel $ODF_CHANNEL for OpenShift $version (latest CSV within channel via OLM)"
}
# Refuse to silently reuse any ODF subscription pinned to a different minor.
check_existing_odf_channels() {
  local wanted="$1"
  oc get subscriptions.operators.coreos.com -n openshift-storage -o json 2>/dev/null | ODF_EXPECTED_CHANNEL="$wanted" python3 -c '
import json,os,sys
j=json.load(sys.stdin); target=os.environ["ODF_EXPECTED_CHANNEL"]
for sub in j.get("items",[]):
 spec=sub.get("spec",{});pkg=spec.get("name",""); channel=spec.get("channel","")
 if pkg in ("odf-operator","mcg-operator","ocs-operator","odf-dependencies","cephcsi-operator","ocs-client-operator","odf-csi-addons-operator","odf-external-snapshotter-operator","odf-prometheus-operator","recipe","rook-ceph-operator") or pkg.startswith(("odf-","ocs-")):
  if channel!=target:
   print("Existing ODF-family Subscription {} uses {}; expected {}. Finish ODF reset or follow supported upgrade process.".format(sub["metadata"]["name"],channel,target),file=sys.stderr)
   sys.exit(1)
' || die "Existing ODF installation differs from $wanted. Refusing an unsafe mixed-version install."
}
# ensure_olm package namespace channel source mode [startingCSV] [expectedCSVregex]
ensure_olm() {
  local pkg="$1" ns="$2" channel="$3" source="$4" mode="$5" starting="${6:-}" expected="${7:-}" old
  [[ "${pkg}" != cloud-native-postgresql ]] || die "Refusing EDB package; use cloudnative-pg."
  old="$(oc get subscriptions.operators.coreos.com -A -o json | PKG="$pkg" python3 -c '
import json,sys,os
for s in json.load(sys.stdin).get("items",[]):
 if s.get("spec",{}).get("name")==os.environ["PKG"]:
  print(s["metadata"]["namespace"]+"/"+s["metadata"]["name"])
' )"
  if [[ -n "$old" ]]; then
    if [[ "$old" != "$ns/$pkg" ]]; then
      warn "Found existing subscription $old for $pkg; will reuse, not create a second installation."
    else log "Reusing $pkg subscription in $ns"; fi
    local actual_ns="${old%%/*}" actual_name="${old#*/}"
    # Do not change preinstalled operator's channel or install plan.
    if [[ -n "$expected" ]]; then
      wait_for "CSV for existing $pkg" "${OPERATOR_TIMEOUT:-2400}" 15 check_sub_csv "$actual_ns" "$actual_name" "$expected"
    else
      wait_for "CSV for existing $pkg" "${OPERATOR_TIMEOUT:-2400}" 15 check_sub_csv "$actual_ns" "$actual_name" ".*"
    fi
    return
  fi
  # Check catalog channel before creating a subscription.
  oc get packagemanifest "$pkg" -n openshift-marketplace -o json | CHANNEL="$channel" python3 -c '
import os,json,sys
j=json.load(sys.stdin); names=[c.get("name") for c in j.get("status",{}).get("channels",[])]
if os.environ["CHANNEL"] not in names:
 print("Channel {} unavailable; catalog offers {}".format(os.environ["CHANNEL"],names),file=sys.stderr);sys.exit(1)
' || die "Catalog validation failed for $pkg / $channel"
  ensure_group "$ns" "$pkg-og" "$mode"
  log "Installing $pkg ($channel from $source) in $ns"
  local csv_line=''
  [[ -z "$starting" ]] || csv_line="  startingCSV: $starting"
  cat <<YAML | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: $pkg
  namespace: $ns
spec:
  name: $pkg
  channel: $channel
  source: $source
  sourceNamespace: openshift-marketplace
  installPlanApproval: ${OLM_APPROVAL:-Automatic}
${csv_line}
YAML
  if [[ -n "$expected" ]]; then
    wait_for "installed $pkg CSV matches $expected" "${OPERATOR_TIMEOUT:-2400}" 15 check_sub_csv "$ns" "$pkg" "$expected"
  else
    wait_for "installed $pkg CSV succeeded" "${OPERATOR_TIMEOUT:-2400}" 15 check_sub_csv "$ns" "$pkg" '.*'
  fi
}
check_sub_csv() {
  local ns="$1" subscription="$2" expected="$3" csv phase
  csv="$(oc get subscription "$subscription" -n "$ns" -o jsonpath='{.status.installedCSV}' 2>/dev/null || :)"
  [[ -n "$csv" && "$csv" =~ $expected ]] || return 1
  phase="$(oc get csv "$csv" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || :)"
  [[ "$phase" == Succeeded ]]
}
check_ready_condition() {
  local ns=(); [[ -z "${3:-}" ]] || ns=(-n "$3")
  oc get "$1" "$2" "${ns[@]}" -o json | python3 -c '
import json,sys
j=json.load(sys.stdin); status=j.get("status",{}); phases=("ready","healthy")
if str(status.get("phase","")).lower() in phases: sys.exit(0)
for c in status.get("conditions",[]):
 if c.get("type") in ("Ready","Available","ClusterReady") and c.get("status")=="True": sys.exit(0)
sys.exit(1)'
}
json_patch() { local kind="$1" name="$2" patch="$3"; oc patch "$kind" "$name" --type=merge -p "$patch"; }
# Authentication is an OpenShift session, NOT a Keycloak administrator password.
# The optional browser flow is appropriate for Keycloak OIDC and MFA.
check_oc() {
  need oc; need python3; need base64
  local method="${OPENSHIFT_AUTH_MODE:-existing}" v actual_user
  case "$method" in
    existing|web) ;;
    *) die "OPENSHIFT_AUTH_MODE must be existing or web (got '$method')" ;;
  esac
  if ! oc whoami >/dev/null 2>&1; then
    if [[ "$method" == web ]]; then
      log 'No authenticated oc session; initiating OpenShift browser login (Keycloak-compatible).'
      if [[ -n "${OPENSHIFT_API_URL:-}" ]]; then
        oc login "$OPENSHIFT_API_URL" --web || die 'Browser login failed; log in using the OpenShift web console and retry.'
      else
        oc login --web || die 'Browser login failed; set OPENSHIFT_API_URL or log in manually and retry.'
      fi
    else
      die 'No authenticated oc session. First use oc login --web or Copy login command in the OpenShift console; alternatively set OPENSHIFT_AUTH_MODE=web.'
    fi
  fi
  actual_user="$(oc whoami)"
  [[ -z "${OPENSHIFT_EXPECTED_ADMIN_USER:-}" || "$actual_user" == "$OPENSHIFT_EXPECTED_ADMIN_USER" ]] || die "Logged in as $actual_user, expected $OPENSHIFT_EXPECTED_ADMIN_USER. Refusing to proceed against the wrong identity."
  [[ "$(oc auth can-i '*' '*' --all-namespaces)" == yes ]] || die "OpenShift user '$actual_user' is not cluster-admin-equivalent. Grant the appropriate cluster role to this OpenShift identity before running setup. A Keycloak realm admin password does not grant OpenShift RBAC."
  v="$(oc get clusterversion version -o jsonpath='{.status.desired.version}')"
  [[ "$v" =~ ^4\.([0-9]+)\.([0-9]+)([+-].*)?$ ]] || die "Unrecognized OpenShift version: $v"
  (( 10#${BASH_REMATCH[1]} >= 21 )) || die "Requires OpenShift 4.21 or newer; cluster reports $v"
  [[ "$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.type}')" == AWS ]] || die 'Expected AWS infrastructure.'
  log "Authenticated as $actual_user, OpenShift $v on AWS, cluster-wide administrator access verified"
}
