#!/usr/bin/env bash
# Two-stage demo: create RHOAI project in UI, then --prepare before Catalog deployment;
# --apply after Catalog deployment, RHOAI Registry and Keycloak UI setup.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/setup-mcp-demo.conf"
MODE="${1:---check}"
[[ $# -eq 1 && ( "$MODE" == --prepare || "$MODE" == --check || "$MODE" == --apply ) ]] || { echo "Usage: $0 [--prepare|--check|--apply]" >&2; exit 2; }
log(){ printf '[mcp-demo] %s\n' "$*"; }
die(){ printf '[mcp-demo] ERROR: %s\n' "$*" >&2; exit 1; }
for cmd in oc python3 openssl; do command -v "$cmd" >/dev/null || die "Requires $cmd"; done
oc whoami >/dev/null || die 'oc login required'
[[ "$(oc auth can-i '*' '*' --all-namespaces)" == yes ]] || die 'cluster admin needed'
# Make all generated manifest names and DNS labels safe.
for name in "$DEMO_NAMESPACE" "$DEMO_SERVER" "$DEMO_SA" "$DEMO_ROUTE" "$DEMO_REGISTRATION" "$DEMO_GATEWAY" "$DEMO_GATEWAY_NAMESPACE"; do
  [[ "$name" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die "Invalid resource name $name"
done
wait_for(){ local description="$1"; shift; local end=$((SECONDS+DEMO_WAIT_SECONDS)); until "$@" >/dev/null 2>&1; do (( SECONDS < end )) || die "Timed out: $description"; sleep 10; done; log "Ready: $description"; }
condition(){ [[ "$(oc get "$1" "$2" -n "$3" -o jsonpath="{.status.conditions[?(@.type=='$4')].status}" 2>/dev/null)" == True ]]; }
# HTTPRoute conditions live under status.parents[].conditions, not status.conditions.
httproute_condition(){
  oc get httproute "$DEMO_ROUTE" -n "$DEMO_GATEWAY_NAMESPACE" -o json | python3 -c '
import json,sys
obj=json.load(sys.stdin); expected=sys.argv[1]
sys.exit(0 if any(c.get("type")==expected and c.get("status")=="True"
    for parent in obj.get("status",{}).get("parents",[])
    for c in parent.get("conditions",[])) else 1)' "$1"
}
registration_ready(){ condition mcpserverregistration "$DEMO_REGISTRATION" "$DEMO_GATEWAY_NAMESPACE" Ready; }
vs_in_secret(){
  oc get secret mcp-gateway-config -n "$DEMO_GATEWAY_NAMESPACE" -o json | EXPECT_NS="$DEMO_GATEWAY_NAMESPACE" EXPECT_ADMIN="$DEMO_ADMIN_VSERVER" EXPECT_USER="$DEMO_USER_VSERVER" EXPECT_REG="$DEMO_REGISTRATION" python3 -c '
import sys,json,os,base64
x=json.load(sys.stdin); v=base64.b64decode(x["data"]["config.yaml"]).decode()
# No YAML dependency; check complete config lines rather than substrings.
lines=set(v.splitlines())
needed=["- name: "+os.environ["EXPECT_NS"]+"/"+n for n in (os.environ["EXPECT_ADMIN"],os.environ["EXPECT_USER"])]
needed.append("  name: "+os.environ["EXPECT_NS"]+"/"+os.environ["EXPECT_REG"])
sys.exit(0 if all(n in lines for n in needed) else 1)' 2>/dev/null
}
get_host(){ oc get ingresscontroller default -n openshift-ingress-operator -o jsonpath='{.status.domain}'; }
app_domain="$(get_host)"; [[ -n "$app_domain" ]] || die 'Ingress domain missing'
public_host="mcp.$app_domain"
backend_host="$DEMO_SERVER.$app_domain"
issuer="${DEMO_KEYCLOAK_ISSUER:-$(oc get oauth cluster -o json | python3 -c 'import json,sys; o=json.load(sys.stdin); x=[p for p in o.get("spec",{}).get("identityProviders",[]) if p.get("name")=="rhbk" and p.get("type")=="OpenID"]; print(x[0]["openID"]["issuer"] if x else "")')}"
[[ -n "$issuer" ]] || die 'Keycloak issuer not found. Configure DEMO_KEYCLOAK_ISSUER.'
[[ "$issuer" == https://* ]] || die 'Only HTTPS OIDC issuer supported'
# PREPARE: demo-scoped identities and backend ConfigMap only; project is created in RHOAI UI.
prepare(){
  oc get namespace "$DEMO_NAMESPACE" >/dev/null 2>&1 || die "First create AI project $DEMO_NAMESPACE in RHOAI UI"
  [[ "$(oc get namespace "$DEMO_NAMESPACE" -o jsonpath='{.metadata.labels.opendatahub\.io/dashboard}')" == true ]] || die "Namespace $DEMO_NAMESPACE exists but is not an RHOAI AI project; create it through RHOAI UI"
  oc create serviceaccount "$DEMO_SA" -n "$DEMO_NAMESPACE" --dry-run=client -o yaml | oc apply -f -
  for ns in "$DEMO_NAMESPACE" "$DEMO_SECONDARY_NAMESPACE"; do
    oc get ns "$ns" >/dev/null || die "Namespace $ns missing"
    oc create rolebinding mcp-viewer-readonly -n "$ns" --clusterrole=view --serviceaccount="$DEMO_NAMESPACE:$DEMO_SA" --dry-run=client -o yaml | oc apply -f -
  done
  if [[ "$DEMO_ALLOW_NAMESPACE_LIST" == true ]]; then
    cat <<YAML | oc apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: mcp-viewer-namespace-reader
rules:
- apiGroups: [""]
  resources: ["namespaces"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: mcp-viewer-namespace-reader
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: mcp-viewer-namespace-reader
subjects:
- kind: ServiceAccount
  namespace: $DEMO_NAMESPACE
  name: $DEMO_SA
YAML
  fi
  # ConfigMap with upstream OpenShift MCP v0.4 format; do not change server image.
  local tmp; tmp="$(mktemp)"; trap 'rm -f "$tmp"' RETURN
  cat > "$tmp" <<'TOML'
port = "8080"
read_only = true
cluster_provider_strategy = "in-cluster"
toolsets = ["core", "config"]

[[denied_resources]]
group = ""
version = "v1"
kind = "Secret"
TOML
  oc create configmap "$DEMO_CONFIGMAP" -n "$DEMO_NAMESPACE" --from-file="config.toml=$tmp" --dry-run=client -o yaml | oc apply -f -
  log 'Preparation complete. Next: deploy MCP server in RHOAI Catalog, register the server in RHOAI UI, configure Keycloak, then run --apply.'
  log "Direct server URL for RHOAI MCP Registry: http://$DEMO_SERVER.$DEMO_NAMESPACE.svc.cluster.local:8080/mcp"
}
check(){
  oc get gateway "$DEMO_GATEWAY" -n "$DEMO_GATEWAY_NAMESPACE" >/dev/null || die 'Run setup-mcp.sh first'
  oc get mcpserver "$DEMO_SERVER" -n "$DEMO_NAMESPACE" >/dev/null || die 'Deploy demo MCP server through RHOAI Catalog first'
  [[ "$(oc get mcpserver "$DEMO_SERVER" -n "$DEMO_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" == True ]] || die 'MCP server not Ready'
  oc get svc "$DEMO_SERVER" -n "$DEMO_NAMESPACE" >/dev/null || die 'Backend Service absent'
  oc get secret authorino-server-cert -n kuadrant-system >/dev/null || die 'Authorino TLS not configured; run MaaS setup first'
  log "Preflight passed: issuer=$issuer, gateway=$DEMO_GATEWAY_NAMESPACE/$DEMO_GATEWAY, backend=$DEMO_NAMESPACE/$DEMO_SERVER"
}
apply_demo(){
  # Native, scoped cross-namespace reference.
  cat <<YAML | oc apply -f -
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-mcp-gateway-backend
  namespace: $DEMO_NAMESPACE
spec:
  from:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    namespace: $DEMO_GATEWAY_NAMESPACE
  to:
  - group: ""
    kind: Service
    name: $DEMO_SERVER
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: $DEMO_ROUTE
  namespace: $DEMO_GATEWAY_NAMESPACE
spec:
  parentRefs:
  - name: $DEMO_GATEWAY
    namespace: $DEMO_GATEWAY_NAMESPACE
    sectionName: mcp
  hostnames:
  - $backend_host
  rules:
  - matches:
    - path: {type: PathPrefix, value: /mcp}
    filters:
    - type: RequestHeaderModifier
      requestHeaderModifier:
        remove: [Authorization]
    backendRefs:
    - name: $DEMO_SERVER
      namespace: $DEMO_NAMESPACE
      port: 8080
YAML
  wait_for 'MCP backend route accepted' httproute_condition Accepted
  wait_for 'MCP backend cross-ns refs resolved' httproute_condition ResolvedRefs
  cat <<YAML | oc apply -f -
apiVersion: mcp.kuadrant.io/v1alpha1
kind: MCPServerRegistration
metadata:
  name: $DEMO_REGISTRATION
  namespace: $DEMO_GATEWAY_NAMESPACE
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: $DEMO_ROUTE
    namespace: $DEMO_GATEWAY_NAMESPACE
  path: /mcp
  prefix: $DEMO_PREFIX
  state: Enabled
  userSpecificList: Disabled
YAML
  wait_for 'MCP registration Ready/13 discovered' registration_ready
  count="$(oc get mcpserverregistration "$DEMO_REGISTRATION" -n "$DEMO_GATEWAY_NAMESPACE" -o jsonpath='{.status.discoveredTools}')"
  [[ "$count" == 13 ]] || die "Expected 13 discovered tools, got '$count'; verify upstream configuration"
  cat <<YAML | oc apply -f -
apiVersion: mcp.kuadrant.io/v1alpha1
kind: MCPVirtualServer
metadata:
  name: $DEMO_ADMIN_VSERVER
  namespace: $DEMO_GATEWAY_NAMESPACE
spec:
  description: All 13 OpenShift MCP tools
  tools:
  - ${DEMO_PREFIX}events_list
  - ${DEMO_PREFIX}namespaces_list
  - ${DEMO_PREFIX}nodes_log
  - ${DEMO_PREFIX}nodes_stats_summary
  - ${DEMO_PREFIX}nodes_top
  - ${DEMO_PREFIX}pods_get
  - ${DEMO_PREFIX}pods_list
  - ${DEMO_PREFIX}pods_list_in_namespace
  - ${DEMO_PREFIX}pods_log
  - ${DEMO_PREFIX}pods_top
  - ${DEMO_PREFIX}projects_list
  - ${DEMO_PREFIX}resources_get
  - ${DEMO_PREFIX}resources_list
---
apiVersion: mcp.kuadrant.io/v1alpha1
kind: MCPVirtualServer
metadata:
  name: $DEMO_USER_VSERVER
  namespace: $DEMO_GATEWAY_NAMESPACE
spec:
  description: Restricted OpenShift MCP tools
  tools:
  - ${DEMO_PREFIX}pods_get
  - ${DEMO_PREFIX}pods_list_in_namespace
  - ${DEMO_PREFIX}pods_log
YAML
  wait_for 'Gateway configuration has both virtual servers' vs_in_secret
  # Same Envoy-to-Authorino TLS transport as working MaaS configuration.
  # Deliberately not attached to shared Authorino or OLM CRDs.
  cat <<YAML | oc apply -f -
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata:
  name: mcp-gateway-authn-ssl
  namespace: $DEMO_GATEWAY_NAMESPACE
spec:
  priority: -1
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: $DEMO_GATEWAY
  configPatches:
  - applyTo: CLUSTER
    match:
      cluster:
        service: authorino-authorino-authorization.kuadrant-system.svc.cluster.local
    patch:
      operation: ADD
      value:
        name: kuadrant-auth-service
        type: STRICT_DNS
        connect_timeout: 1s
        lb_policy: ROUND_ROBIN
        http2_protocol_options: {}
        load_assignment:
          cluster_name: kuadrant-auth-service
          endpoints:
          - lb_endpoints:
            - endpoint:
                address:
                  socket_address:
                    address: authorino-authorino-authorization.kuadrant-system.svc.cluster.local
                    port_value: 50051
        transport_socket:
          name: envoy.transport_sockets.tls
          typed_config:
            '@type': type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.UpstreamTlsContext
            common_tls_context:
              validation_context:
                trusted_ca:
                  filename: /var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt
YAML
  # AuthPolicy shapes verified on v1/RHCL 1.4.3 lab. No unsupported jwt.audiences.
  cat <<YAML | oc apply -f -
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata:
  name: mcp-gateway-keycloak-auth
  namespace: $DEMO_GATEWAY_NAMESPACE
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: Gateway
    name: $DEMO_GATEWAY
    sectionName: mcp
  defaults:
    rules:
      authentication:
        keycloak:
          jwt:
            issuerUrl: $issuer
      authorization:
        permitted-identity:
          patternMatching:
            patterns:
            - predicate: "auth.identity.azp == '$DEMO_KEYCLOAK_CLIENT' && auth.identity.preferred_username in ['$DEMO_ADMIN_USERNAME', '$DEMO_USER_USERNAME']"
      response:
        success:
          headers:
            x-mcp-virtualserver:
              plain:
                expression: "auth.identity.preferred_username == '$DEMO_ADMIN_USERNAME' ? '$DEMO_GATEWAY_NAMESPACE/$DEMO_ADMIN_VSERVER' : '$DEMO_GATEWAY_NAMESPACE/$DEMO_USER_VSERVER'"
        unauthenticated:
          code: 401
          body:
            value: '{"error":"Unauthorized","message":"Keycloak authentication required"}'
        unauthorized:
          code: 403
          body:
            value: '{"error":"Forbidden","message":"MCP Gateway access denied"}'
---
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata:
  name: mcp-backend-tool-auth
  namespace: $DEMO_GATEWAY_NAMESPACE
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: $DEMO_ROUTE
  rules:
    authentication:
      keycloak:
        jwt:
          issuerUrl: $issuer
    authorization:
      allowed-mcp-tools:
        patternMatching:
          patterns:
          - predicate: >-
              auth.identity.azp == '$DEMO_KEYCLOAK_CLIENT'
              && auth.identity.preferred_username in ['$DEMO_ADMIN_USERNAME', '$DEMO_USER_USERNAME']
              && request.headers.exists(h, h == 'x-mcp-toolname')
              && (auth.identity.preferred_username == '$DEMO_ADMIN_USERNAME'
                  || (auth.identity.preferred_username == '$DEMO_USER_USERNAME'
                      && request.headers['x-mcp-toolname'] in ['pods_get', 'pods_list_in_namespace', 'pods_log']))
    response:
      unauthenticated: {code: 401, body: {value: '{"error":"Unauthorized"}'}}
      unauthorized: {code: 403, body: {value: '{"error":"Forbidden","message":"MCP tool access denied"}'}}
YAML
  wait_for 'MCP Gateway JWT AuthPolicy Accepted' condition authpolicy mcp-gateway-keycloak-auth "$DEMO_GATEWAY_NAMESPACE" Accepted
  wait_for 'MCP Gateway JWT AuthPolicy Enforced' condition authpolicy mcp-gateway-keycloak-auth "$DEMO_GATEWAY_NAMESPACE" Enforced
  wait_for 'MCP tool AuthPolicy Accepted' condition authpolicy mcp-backend-tool-auth "$DEMO_GATEWAY_NAMESPACE" Accepted
  wait_for 'MCP tool AuthPolicy Enforced' condition authpolicy mcp-backend-tool-auth "$DEMO_GATEWAY_NAMESPACE" Enforced
  if [[ "$DEMO_CREATE_PLAYGROUND_ROUTE" == true ]]; then
    local lb_service
    lb_service="$(oc get svc -n "$DEMO_GATEWAY_NAMESPACE" -l "gateway.networking.k8s.io/gateway-name=$DEMO_GATEWAY" -o json | python3 -c 'import sys,json; xs=[x for x in json.load(sys.stdin)["items"] if any(p.get("name")=="mcp" and p.get("port")==443 for p in x.get("spec",{}).get("ports",[]))]; print(xs[0]["metadata"]["name"] if len(xs)==1 else "")')"
    [[ -n "$lb_service" ]] || die 'No unique HTTPS Gateway Service'
    cat <<YAML | oc apply -f -
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: $DEMO_PLAYGROUND_ROUTE_NAME
  namespace: $DEMO_GATEWAY_NAMESPACE
spec:
  host: $public_host
  to:
    kind: Service
    name: $lb_service
  port:
    targetPort: mcp
  tls:
    termination: passthrough
YAML
    wait_for 'Playground OpenShift Route admitted' route_admitted
  fi
  # Publish direct backend to Playground only after UI deployment and post-install checks.
  DEMO_CM_NS="$DEMO_RHOAI_NAMESPACE" DEMO_CM_NAME="$DEMO_PLAYGROUND_DISCOVERY_CM" DEMO_URL="http://$DEMO_SERVER.$DEMO_NAMESPACE.svc.cluster.local:8080/mcp" python3 - <<'PY'
import json,subprocess,os
ns=os.environ['DEMO_CM_NS']; name=os.environ['DEMO_CM_NAME']; url=os.environ['DEMO_URL']
entry=json.dumps({'url':url,'description':'Read-only OpenShift MCP demo backend'},separators=(',',':'))
obj={'apiVersion':'v1','kind':'ConfigMap','metadata':{'namespace':ns,'name':name},'data':{'OpenShift-MCP-Demo':entry}}
if subprocess.run(['oc','get','configmap',name,'-n',ns],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode:
    subprocess.run(['oc','apply','-f','-'],input=json.dumps(obj),text=True,check=True)
else:
    subprocess.run(['oc','patch','configmap',name,'-n',ns,'--type=merge','-p',json.dumps({'data':obj['data']})],check=True)
PY
  # Preserve the existing direct MCP Discovery entry.
  DEMO_CM_NS="$DEMO_RHOAI_NAMESPACE" DEMO_CM_NAME="$DEMO_PLAYGROUND_DISCOVERY_CM" DEMO_URL="https://$public_host/mcp" python3 - <<'PY'
import os,subprocess,json
ns=os.environ['DEMO_CM_NS']; name=os.environ['DEMO_CM_NAME']; url=os.environ['DEMO_URL']
entry=json.dumps({'url':url,'description':'Keycloak-authenticated OpenShift MCP Gateway'},separators=(',',':'))
obj={'apiVersion':'v1','kind':'ConfigMap','metadata':{'namespace':ns,'name':name},'data':{'OpenShift-MCP-Gateway':entry}}
if subprocess.run(['oc','get','configmap',name,'-n',ns],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode:
    subprocess.run(['oc','apply','-f','-'],input=json.dumps(obj),text=True,check=True)
else:
    subprocess.run(['oc','patch','configmap',name,'-n',ns,'--type=merge','-p',json.dumps({'data':obj['data']})],check=True)
PY
  log "MCP Gateway endpoint for RHOAI UI Registry: https://$public_host/mcp"
  log "Gateway Registry server.json: {\"name\":\"org.redhat/openshift-mcp-gateway\",\"version\":\"0.7.1\",\"description\":\"Keycloak-authenticated MCP Gateway with per-user tool selection\",\"remotes\":[{\"type\":\"streamable-http\",\"url\":\"https://$public_host/mcp\"}]}"
  log 'Post-UI federation and policy objects are ready. Validate HTTPS 401 without a token, then use user-get-token.sh/admin-get-token.sh in RHOAI Playground.'
  log 'IMPORTANT: tool-level denial of manually constructed unauthorized calls has NOT been verified by this script.'
}
route_admitted(){ condition route "$DEMO_PLAYGROUND_ROUTE_NAME" "$DEMO_GATEWAY_NAMESPACE" Admitted || [[ "$(oc get route "$DEMO_PLAYGROUND_ROUTE_NAME" -n "$DEMO_GATEWAY_NAMESPACE" -o jsonpath='{.status.ingress[0].conditions[?(@.type=="Admitted")].status}' 2>/dev/null)" == True ]]; }
case "$MODE" in
  --prepare) prepare;;
  --check) check;;
  --apply) check; apply_demo;;
esac
