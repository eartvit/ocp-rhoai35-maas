#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/setup-mcp.conf"
MODE="${1:---check}"
[[ $# -eq 1 && ( "$MODE" == --check || "$MODE" == --apply ) ]] || { echo "Usage: $0 --check|--apply" >&2; exit 2; }
log(){ printf '[setup-mcp] %s\n' "$*"; }
die(){ echo "[setup-mcp] ERROR: $*" >&2; exit 1; }
command -v oc >/dev/null || die 'oc required'
command -v python3 >/dev/null || die 'python3 required'
command -v openssl >/dev/null || die 'openssl required for TLS validation'
oc whoami >/dev/null || die 'oc session required; log in as cluster-admin'
[[ "$(oc auth can-i '*' '*' --all-namespaces)" == yes ]] || die 'cluster-admin authorization required'
jsonval(){ python3 -c 'import json,sys; d=json.load(sys.stdin); path=sys.argv[1].split(".");
for k in path: d=d.get(k,{}) if isinstance(d,dict) else {}
print(d if isinstance(d,str) else "")' "$1"; }
wait_for(){ local label="$1" timeout="$2"; shift 2; local end=$((SECONDS+timeout)); until "$@" >/dev/null 2>&1; do ((SECONDS<end)) || die "Timed out: $label"; sleep 10; done; log "Ready: $label"; }
get_crd(){ oc get crd "$1" >/dev/null 2>&1; }
lifecycle_ready(){ [[ "$(oc get dsc "$MCP_DSC_NAME" -o jsonpath='{.status.conditions[?(@.type=="MCPLifecycleOperatorReady")].status}')" == True ]]; }
version="$(oc get clusterversion version -o jsonpath='{.status.desired.version}')"
[[ "$version" =~ ^4\.21\. ]] || die "This archived limited demo is for OCP 4.21.x only; got $version"
minor=21
oc get dsc "$MCP_DSC_NAME" >/dev/null || die "RHOAI DSC $MCP_DSC_NAME not found"
rhcl="$(oc get csv -n openshift-operators -o json | python3 -c 'import json,sys; a=json.load(sys.stdin)["items"]; matches=sorted(set(x["metadata"]["name"] for x in a if x["metadata"]["name"].startswith("rhcl-operator") and x.get("status",{}).get("phase")=="Succeeded")); print(matches[-1] if matches else "")')"
[[ -n "$rhcl" ]] || die 'RHCL operator is not installed/succeeded'
oc get gatewayclass "$MCP_GATEWAY_CLASS" >/dev/null || die "GatewayClass $MCP_GATEWAY_CLASS absent"
pack="$(oc get packagemanifest "$MCP_OPERATOR_PACKAGE" -n openshift-marketplace -o json)" || die 'MCP gateway package absent from catalog'
echo "$pack" | python3 -c 'import json,sys; d=json.load(sys.stdin)["status"]; assert any(c["name"]==sys.argv[1] for c in d["channels"]),"preview channel missing"' "$MCP_OPERATOR_CHANNEL" || die 'MCP gateway preview channel unavailable'
ingress="$(oc get ingresscontroller default -n openshift-ingress-operator -o json)"
domain="$(printf '%s' "$ingress" | jsonval status.domain)"
secret="${MCP_INGRESS_TLS_SECRET:-$(printf '%s' "$ingress" | jsonval spec.defaultCertificate.name)}"
[[ -n "$domain" ]] || die 'IngressController status.domain is empty'
[[ -n "$secret" ]] || die 'No configured ingress defaultCertificate Secret; supply MCP_INGRESS_TLS_SECRET after obtaining a certificate'
host="${MCP_HOSTNAME:-mcp.$domain}"
[[ "$host" =~ ^[a-zA-Z0-9.-]+$ ]] || die "Invalid MCP hostname: $host"
cert="$(oc get secret "$secret" -n openshift-ingress -o json)" || die "Ingress TLS Secret $secret missing"
printf '%s' "$cert" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["type"]=="kubernetes.io/tls"; assert "tls.crt" in d["data"] and "tls.key" in d["data"]' || die 'Invalid TLS Secret'
printf '%s' "$cert" | python3 -c 'import json,sys,base64; d=json.load(sys.stdin); sys.stdout.buffer.write(base64.b64decode(d["data"]["tls.crt"]))' | openssl x509 -noout -checkhost "$host" | grep -q 'does match certificate' || die "TLS certificate does not cover $host"
[[ "$MCP_GATEWAY_NAMESPACE" == "$MCP_NAMESPACE" ]] || die 'Limited-demo Gateway and extension must be in the same namespace'
[[ "$MCP_INTERNAL_HOSTNAME" =~ ^[a-zA-Z0-9.-]+$ ]] || die 'Invalid MCP internal hostname'
if oc get gateway "$MCP_GATEWAY_NAME" -n openshift-ingress >/dev/null 2>&1; then
  die "Legacy Gateway exists in openshift-ingress; remove it with the separately reviewed rebuild reset before --apply"
fi
[[ "$MCP_GATEWAY_NAME" != maas-default-gateway ]] || die 'Refusing to manage the MaaS Gateway'
log "OCP=$version RHCL=$rhcl channel=$MCP_OPERATOR_CHANNEL"
log "Gateway=$MCP_GATEWAY_NAMESPACE/$MCP_GATEWAY_NAME host=$host TLS=$secret"
if ((minor<22)); then
  log 'WARNING: RHOAI MCP Lifecycle is documented for OCP 4.22+; enabling on 4.21 is an unsupported demo experiment when ENABLE_MCP_LIFECYCLE=true.'
fi
[[ "$MODE" == --apply ]] || { log 'Preflight passed (read-only); use --apply to install.'; exit 0; }
oc create namespace "$MCP_NAMESPACE" --dry-run=client -o yaml | oc apply -f -
# Existing Subscription is never reconfigured silently.
if oc get subscription "$MCP_OPERATOR_PACKAGE" -n "$MCP_NAMESPACE" >/dev/null 2>&1; then
  existing="$(oc get subscription "$MCP_OPERATOR_PACKAGE" -n "$MCP_NAMESPACE" -o jsonpath='{.spec.channel}')"
  [[ "$existing" == "$MCP_OPERATOR_CHANNEL" ]] || die "Existing subscription channel $existing differs from $MCP_OPERATOR_CHANNEL"
else
  cat <<YAML | oc apply -n "$MCP_NAMESPACE" -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: mcp-gateway
spec:
  targetNamespaces:
    - $MCP_NAMESPACE
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: $MCP_OPERATOR_PACKAGE
spec:
  channel: $MCP_OPERATOR_CHANNEL
  name: $MCP_OPERATOR_PACKAGE
  source: $MCP_OPERATOR_SOURCE
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
YAML
fi
wait_for 'MCP Gateway Operator CSV Succeeded' "$MCP_OPERATOR_TIMEOUT" bash -c 'oc get csv -n "$1" -o json | python3 -c '\''import json,sys; a=json.load(sys.stdin)["items"]; assert any(x["metadata"]["name"].startswith("mcp-gateway") and x.get("status",{}).get("phase")=="Succeeded" for x in a)'\''' _ "$MCP_NAMESPACE"
wait_for 'MCPGatewayExtension CRD' "$MCP_RESOURCE_TIMEOUT" get_crd mcpgatewayextensions.mcp.kuadrant.io
wait_for 'MCPServerRegistration CRD' "$MCP_RESOURCE_TIMEOUT" get_crd mcpserverregistrations.mcp.kuadrant.io
# Gateway and extension share mcp-system. Do not overwrite an unrelated Gateway.
if oc get gateway "$MCP_GATEWAY_NAME" -n "$MCP_NAMESPACE" >/dev/null 2>&1; then
  owner="$(oc get gateway "$MCP_GATEWAY_NAME" -n "$MCP_NAMESPACE" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}')"
  [[ "$owner" == setup-mcp || "$owner" == mcp-rebuild ]] || die 'Existing Gateway is not owned by this demo installer/rebuild; refusing to overwrite'
fi
# Gateway API requires the TLS Secret to be colocated with the Gateway.
# Recopy the ingress certificate on each apply, allowing rotation to be picked up.
printf '%s' "$cert" | python3 -c '
import json,sys
s=json.load(sys.stdin)
print(json.dumps({"apiVersion":"v1","kind":"Secret","metadata":{"name":"mcp-gateway-tls","namespace":sys.argv[1],"labels":{"app.kubernetes.io/managed-by":"setup-mcp"}},"type":"kubernetes.io/tls","data":{"tls.crt":s["data"]["tls.crt"],"tls.key":s["data"]["tls.key"]}}))
' "$MCP_NAMESPACE" | oc apply -f - >/dev/null
log "TLS certificate copied to $MCP_NAMESPACE/mcp-gateway-tls"
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
      hostname: $host
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
YAML
gateway_programmed(){ [[ "$(oc get gateway "$MCP_GATEWAY_NAME" -n "$MCP_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}')" == True ]]; }
wait_for 'Gateway Programmed=True' "$MCP_RESOURCE_TIMEOUT" gateway_programmed
oc wait -n "$MCP_NAMESPACE" --for=condition=Ready "mcpgatewayextension/$MCP_EXTENSION_NAME" --timeout="${MCP_RESOURCE_TIMEOUT}s" || die 'MCPGatewayExtension not Ready'
wait_for 'Operator-created HTTPRoute' "$MCP_RESOURCE_TIMEOUT" oc get httproute mcp-gateway-route -n "$MCP_NAMESPACE"
log 'Both listeners configured. Gateway and extension Ready; broker route created.'
log 'NOTE: Port 8080 is not proven private merely by its hostname. Do not publish sensitive backends before external-exposure and AuthPolicy checks.'
if [[ "$ENABLE_MCP_LIFECYCLE" == true ]]; then
  if ((minor<22)); then
    log 'WARNING: MCP Lifecycle on OCP 4.21 is outside Red Hat documented support; proceeding as explicitly configured.'
  fi
  oc patch dsc "$MCP_DSC_NAME" --type=merge -p '{"spec":{"components":{"mcplifecycleoperator":{"managementState":"Managed"}}}}'
  oc patch odhdashboardconfig "$MCP_DASHBOARD_CONFIG_NAME" -n "$MCP_DASHBOARD_NAMESPACE" --type=merge -p '{"spec":{"dashboardConfig":{"mcpCatalog":true}}}'
  wait_for 'RHOAI MCP Lifecycle Ready=True' "$MCP_RESOURCE_TIMEOUT" lifecycle_ready
  wait_for 'MCPServer Lifecycle CRD' "$MCP_RESOURCE_TIMEOUT" get_crd mcpservers.mcp.x-k8s.io
  log 'MCP Lifecycle enabled; catalog deployment can now be tested in RHOAI.'
else
  log 'MCP Lifecycle disabled by ENABLE_MCP_LIFECYCLE=false.'
fi
log "MCP Gateway infrastructure installed (limited demo). Endpoint: https://$host/mcp"
log 'No backend HTTPRoute, ReferenceGrant, MCPServerRegistration, MCPVirtualServer, AuthPolicy or MCP server was created.'
log 'On OCP 4.21, direct Playground-to-MCP backend is the validated demo path; Gateway federation/tool policies remain unvalidated.'
log 'Gateway access policy is not configured by this script: configure AuthPolicy before exposing sensitive MCP tools.'
