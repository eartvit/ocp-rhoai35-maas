#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=setup-mcp.conf
source "$HERE/setup-mcp.conf"
MODE="${1:---check}"
[[ $# -le 1 && ( "$MODE" == --check || "$MODE" == --apply ) ]] || { echo "Usage: $0 [--check|--apply]" >&2; exit 2; }
log(){ printf '[setup-mcp] %s\n' "$*"; }
die(){ printf '[setup-mcp] ERROR: %s\n' "$*" >&2; exit 1; }
for executable in oc python3 openssl; do command -v "$executable" >/dev/null || die "$executable required"; done
oc whoami >/dev/null || die 'oc session required'
[[ "$(oc auth can-i '*' '*' --all-namespaces)" == yes ]] || die 'cluster-admin authorization required'
jsonval(){ python3 -c 'import json,sys; d=json.load(sys.stdin)
for k in sys.argv[1].split("."): d=d.get(k,{}) if isinstance(d,dict) else {}
print(d if isinstance(d,str) else "")' "$1"; }
wait_for(){ local label="$1" timeout="$2"; shift 2; local end=$((SECONDS+timeout)); until "$@" >/dev/null 2>&1; do (( SECONDS < end )) || die "Timed out: $label"; sleep 10; done; log "Ready: $label"; }
get_crd(){ oc get crd "$1" >/dev/null 2>&1; }
condition_true(){ [[ "$(oc get "$1" "$2" -n "$3" -o jsonpath="{.status.conditions[?(@.type=='$4')].status}" 2>/dev/null)" == True ]]; }
lifecycle_ready(){ [[ "$(oc get dsc "$MCP_DSC_NAME" -o jsonpath='{.status.conditions[?(@.type=="MCPLifecycleOperatorReady")].status}' 2>/dev/null)" == True ]]; }
version="$(oc get clusterversion version -o jsonpath='{.status.desired.version}')"
[[ "$version" =~ ^4\.([0-9]+)\. ]] || die "Unrecognized OCP version $version"
minor=$((10#${BASH_REMATCH[1]}))
if (( minor < MCP_MIN_OCP_MINOR )); then
  [[ "$minor" == 21 && "${MCP_ALLOW_UNSUPPORTED_421:-false}" == true ]] || die "OCP $version not in supported baseline (4.$MCP_MIN_OCP_MINOR+); set MCP_ALLOW_UNSUPPORTED_421=true for explicit experimental 4.21"
  log 'WARNING: OCP 4.21 MCP Gateway is an experimental exception; federation not validated.'
fi
[[ "$MCP_GATEWAY_NAMESPACE" == "$MCP_NAMESPACE" ]] || die 'Gateway and extension must share namespace in this installer'
[[ "$MCP_GATEWAY_NAME" != maas-default-gateway ]] || die 'Refusing to manage MaaS Gateway'
[[ "$MCP_INTERNAL_HOSTNAME" =~ ^[A-Za-z0-9.-]+$ ]] || die 'Invalid internal hostname'
oc get dsc "$MCP_DSC_NAME" >/dev/null || die "RHOAI DSC $MCP_DSC_NAME missing"
rhcl="$(oc get csv -n openshift-operators -o json | python3 -c 'import json,sys; a=json.load(sys.stdin).get("items",[]); print(",".join(x["metadata"]["name"] for x in a if x["metadata"]["name"].startswith("rhcl-operator.v") and x.get("status",{}).get("phase")=="Succeeded"))')"
[[ -n "$rhcl" ]] || die 'RHCL Operator is not installed and Succeeded'
oc get gatewayclass "$MCP_GATEWAY_CLASS" >/dev/null || die "GatewayClass $MCP_GATEWAY_CLASS missing"
[[ "$(oc get gatewayclass "$MCP_GATEWAY_CLASS" -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}')" == True ]] || die 'GatewayClass not Accepted'
pack="$(oc get packagemanifest "$MCP_OPERATOR_PACKAGE" -n openshift-marketplace -o json)" || die 'MCP operator package missing'
selected_csv="$(printf '%s' "$pack" | python3 -c 'import json,sys; p=json.load(sys.stdin); c=next((x for x in p["status"]["channels"] if x["name"]==sys.argv[1]),None); print(c.get("currentCSV","") if c else "")' "$MCP_OPERATOR_CHANNEL")"
[[ -n "$selected_csv" ]] || die "MCP operator channel $MCP_OPERATOR_CHANNEL absent from catalog"
ingress="$(oc get ingresscontroller default -n openshift-ingress-operator -o json)"
domain="$(printf '%s' "$ingress" | jsonval status.domain)"
secret="${MCP_INGRESS_TLS_SECRET:-$(printf '%s' "$ingress" | jsonval spec.defaultCertificate.name)}"
[[ -n "$domain" && -n "$secret" ]] || die 'Ingress domain or TLS Secret missing'
host="${MCP_HOSTNAME:-mcp.$domain}"
listener_host="${MCP_PUBLIC_LISTENER_HOSTNAME:-*.$domain}"
private_host="${MCP_PRIVATE_HOST:-https://$MCP_GATEWAY_NAME-$MCP_GATEWAY_CLASS.$MCP_NAMESPACE.svc.cluster.local:443}"
[[ "$host" =~ ^[A-Za-z0-9.-]+$ ]] || die "Invalid MCP hostname: $host"
[[ "$listener_host" == "*.$domain" || "$listener_host" == "$host" ]] || die "Listener hostname must be *.$domain or $host"
# Do not expose TLS key through command output.
cert="$(oc get secret "$secret" -n openshift-ingress -o json)" || die 'Ingress TLS Secret missing'
printf '%s' "$cert" | python3 -c 'import json,sys; s=json.load(sys.stdin); assert s["type"]=="kubernetes.io/tls" and all(x in s["data"] for x in ("tls.crt","tls.key"))' || die 'Invalid ingress TLS Secret'
printf '%s' "$cert" | python3 -c 'import json,base64,sys; sys.stdout.buffer.write(base64.b64decode(json.load(sys.stdin)["data"]["tls.crt"]))' | openssl x509 -noout -checkhost "$host" | grep -q 'does match certificate' || die "Certificate does not cover $host"
if oc get gateway "$MCP_GATEWAY_NAME" -n openshift-ingress >/dev/null 2>&1; then die 'Legacy Gateway in openshift-ingress must be handled separately; no automatic cleanup'; fi
if oc get gateway "$MCP_GATEWAY_NAME" -n "$MCP_NAMESPACE" >/dev/null 2>&1; then
  owner="$(oc get gateway "$MCP_GATEWAY_NAME" -n "$MCP_NAMESPACE" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}')"
  [[ "$owner" == setup-mcp || "$owner" == mcp-rebuild ]] || die "Gateway exists but is not managed by setup-mcp ($owner)"
fi
if oc get subscription "$MCP_OPERATOR_PACKAGE" -n "$MCP_NAMESPACE" >/dev/null 2>&1; then
  existing="$(oc get subscription "$MCP_OPERATOR_PACKAGE" -n "$MCP_NAMESPACE" -o jsonpath='{.spec.channel}')"
  [[ "$existing" == "$MCP_OPERATOR_CHANNEL" ]] || die "Existing MCP Subscription channel $existing != $MCP_OPERATOR_CHANNEL"
fi
log "OCP=$version RHCL=$rhcl MCP channel=$MCP_OPERATOR_CHANNEL catalogCSV=$selected_csv"
log "Gateway=$MCP_NAMESPACE/$MCP_GATEWAY_NAME host=$host listener=$listener_host; HTTPS mcp:443 and internal HTTP mcps:8080"
[[ "$MODE" == --apply ]] || { log 'Preflight passed. No resources changed.'; exit 0; }
oc create namespace "$MCP_NAMESPACE" --dry-run=client -o yaml | oc apply -f -
if ! oc get subscription "$MCP_OPERATOR_PACKAGE" -n "$MCP_NAMESPACE" >/dev/null 2>&1; then
  # Existing OperatorGroups must be checked, not overwritten.
  count="$(oc get operatorgroups -n "$MCP_NAMESPACE" -o json | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("items",[])))')"
  if [[ "$count" == 0 ]]; then
    cat <<YAML | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: mcp-gateway
  namespace: $MCP_NAMESPACE
spec:
  targetNamespaces:
    - $MCP_NAMESPACE
YAML
  else
    [[ "$count" == 1 ]] || die 'Multiple OperatorGroups present'
    log 'Reusing existing OperatorGroup; verify it targets this namespace'
  fi
  cat <<YAML | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: $MCP_OPERATOR_PACKAGE
  namespace: $MCP_NAMESPACE
spec:
  channel: $MCP_OPERATOR_CHANNEL
  name: $MCP_OPERATOR_PACKAGE
  source: $MCP_OPERATOR_SOURCE
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
YAML
fi
csv_ready(){ local installed; installed="$(oc get subscription "$MCP_OPERATOR_PACKAGE" -n "$MCP_NAMESPACE" -o jsonpath='{.status.installedCSV}' 2>/dev/null)"; [[ -n "$installed" ]] && [[ "$(oc get csv "$installed" -n "$MCP_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null)" == Succeeded ]]; }
wait_for 'MCP Operator CSV Succeeded' "$MCP_OPERATOR_TIMEOUT" csv_ready
for crd in mcpgatewayextensions.mcp.kuadrant.io mcpserverregistrations.mcp.kuadrant.io mcpvirtualservers.mcp.kuadrant.io; do wait_for "CRD $crd" "$MCP_RESOURCE_TIMEOUT" get_crd "$crd"; done
# Copy certificate only when there is no conflicting Secret owner.
if oc get secret mcp-gateway-tls -n "$MCP_NAMESPACE" >/dev/null 2>&1; then
  owner="$(oc get secret mcp-gateway-tls -n "$MCP_NAMESPACE" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}')"
  [[ "$owner" == setup-mcp ]] || die 'mcp-gateway-tls exists but is not owned by this installer'
fi
printf '%s' "$cert" | python3 -c 'import json,sys; s=json.load(sys.stdin); print(json.dumps({"apiVersion":"v1","kind":"Secret","metadata":{"name":"mcp-gateway-tls","namespace":sys.argv[1],"labels":{"app.kubernetes.io/managed-by":"setup-mcp"}},"type":"kubernetes.io/tls","data":{"tls.crt":s["data"]["tls.crt"],"tls.key":s["data"]["tls.key"]}}))' "$MCP_NAMESPACE" | oc apply -f - >/dev/null
cat <<YAML | oc apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: $MCP_GATEWAY_NAME
  namespace: $MCP_NAMESPACE
  labels:
    app.kubernetes.io/managed-by: setup-mcp
spec:
  gatewayClassName: $MCP_GATEWAY_CLASS
  listeners:
    - name: mcp
      hostname: "$listener_host"
      port: 443
      protocol: HTTPS
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            name: mcp-gateway-tls
      allowedRoutes:
        namespaces:
          from: Same
    - name: mcps
      hostname: $MCP_INTERNAL_HOSTNAME
      port: 8080
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: Same
---
apiVersion: mcp.kuadrant.io/v1alpha1
kind: MCPGatewayExtension
metadata:
  name: $MCP_EXTENSION_NAME
  namespace: $MCP_NAMESPACE
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: Gateway
    name: $MCP_GATEWAY_NAME
    namespace: $MCP_NAMESPACE
    sectionName: mcp
  httpRouteManagement: Enabled
  privateHost: "$private_host"
  publicHost: "$host"
YAML
wait_for 'MCP Gateway Programmed' "$MCP_RESOURCE_TIMEOUT" condition_true gateway "$MCP_GATEWAY_NAME" "$MCP_NAMESPACE" Programmed
wait_for 'MCP GatewayExtension Ready' "$MCP_RESOURCE_TIMEOUT" condition_true mcpgatewayextension "$MCP_EXTENSION_NAME" "$MCP_NAMESPACE" Ready
wait_for 'Operator-managed MCP HTTPRoute created' "$MCP_RESOURCE_TIMEOUT" oc get httproute mcp-gateway-route -n "$MCP_NAMESPACE"
# Verify that both listener definitions survived reconciliation.
for listener in mcp mcps; do
  oc get gateway "$MCP_GATEWAY_NAME" -n "$MCP_NAMESPACE" -o json | python3 -c 'import json,sys; g=json.load(sys.stdin); assert any(x["name"]==sys.argv[1] for x in g["spec"]["listeners"])' "$listener" || die "Listener $listener missing"
done
if [[ "$ENABLE_MCP_LIFECYCLE" == true ]]; then
  if (( minor < 22 )); then log 'WARNING: lifecycle is experimental on OCP 4.21'; fi
  oc patch dsc "$MCP_DSC_NAME" --type=merge -p '{"spec":{"components":{"mcplifecycleoperator":{"managementState":"Managed"}}}}'
  oc patch odhdashboardconfig "$MCP_DASHBOARD_CONFIG_NAME" -n "$MCP_DASHBOARD_NAMESPACE" --type=merge -p '{"spec":{"dashboardConfig":{"mcpCatalog":true}}}'
  wait_for 'MCP Lifecycle Ready' "$MCP_RESOURCE_TIMEOUT" lifecycle_ready
  wait_for 'MCPServer Lifecycle CRD' "$MCP_RESOURCE_TIMEOUT" get_crd mcpservers.mcp.x-k8s.io
fi
log "MCP infrastructure Ready. Endpoint: https://$host/mcp"
log 'Next: bash setup-mcp-demo.sh --prepare; deploy MCPServer via RHOAI catalog; configure Keycloak; bash setup-mcp-demo.sh --apply.'
log 'The mcps:8080 listener is HTTP and not proven private: assess network exposure before connecting sensitive backends.'
