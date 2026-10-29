#!/usr/bin/env bash
# RHOAI 3.5.x MaaS add-on for AWS OpenShift 4.21. Run: bash setup-maas.sh --apply
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/setup-maas.conf"
CLUSTER_CONFIG_FILE="$SCRIPT_DIR/setup-cluster.conf"
MODE=check
for a in "$@"; do case "$a" in --apply) MODE=apply;; --check) MODE=check;; config=*) CONFIG_FILE="${a#config=}";; cluster-config=*) CLUSTER_CONFIG_FILE="${a#cluster-config=}";; *) echo "Usage: bash setup-maas.sh [--check|--apply] [config=FILE] [cluster-config=FILE]" >&2; exit 2;; esac; done
# Read GPU choices from the first script's config, then let MaaS config override.
[[ -f "$CLUSTER_CONFIG_FILE" ]] || { echo "Missing baseline config $CLUSTER_CONFIG_FILE" >&2; exit 1; }
source "$CLUSTER_CONFIG_FILE"
[[ -f "$CONFIG_FILE" ]] || { echo "Missing config $CONFIG_FILE" >&2; exit 1; }
# shellcheck source=setup-maas.conf
source "$CONFIG_FILE"
# shellcheck source=rhoai-common.sh
source "$SCRIPT_DIR/rhoai-common.sh"
trap 'warn "Failed at line $LINENO (exit code $?). Check events and rerun safely."' ERR

rhoai_ready() { check_ready_condition dsc "$DSC_NAME" ''; }
maas_tenant_ready() {
  # RHOAI 3.5 exposes tenant readiness on MaasTenantConfig/default-tenant.
  # The old tenants.maas.opendatahub.io lookup is not this readiness resource.
  oc get maastenantconfig.maas.opendatahub.io "$MAAS_TENANT_NAME" -n "$MAAS_NAMESPACE" -o json 2>/dev/null | python3 -c '
import json,sys
try: status=json.load(sys.stdin).get("status",{})
except (ValueError, OSError): sys.exit(1)
ready=any(c.get("type")=="Ready" and c.get("status")=="True" for c in status.get("conditions",[]))
sys.exit(0 if ready and status.get("phase")=="Active" else 1)'
}
maas_dsc_condition() {
  oc get dsc "$DSC_NAME" -o json | python3 -c '
import json,sys
c=json.load(sys.stdin).get("status",{}).get("conditions",[])
sys.exit(0 if any(x.get("type")=="ModelsAsAServiceReady" and x.get("status")=="True" for x in c) else 1)'
}
preflight() {
  check_oc
  oc get dsc "$DSC_NAME" >/dev/null || die 'No baseline DSC; run setup-cluster.sh first.'
  oc get dsci "$DSCI_NAME" >/dev/null || die 'No baseline DSCI; run setup-cluster.sh first.'
  local rhoai_csv rhcl_csv
  rhoai_csv="$(oc get subscription rhods-operator -n "$RHOAI_OPERATOR_NAMESPACE" -o jsonpath='{.status.installedCSV}' 2>/dev/null || :)"
  [[ "$rhoai_csv" =~ $RHOAI_EXPECTED_CSV_REGEX ]] || die "Expected RHOAI 3.5.x, found '$rhoai_csv'"
  rhcl_csv="$(oc get subscriptions -A -o json | python3 -c '
import json,sys
for x in json.load(sys.stdin).get("items",[]):
 if x.get("spec",{}).get("name")=="rhcl-operator":print(x.get("status",{}).get("installedCSV",""));break')"
  [[ "$rhcl_csv" =~ $RHCL_EXPECTED_CSV_REGEX ]] || die "Expected RHCL 1.4.2+, found '$rhcl_csv'"
  oc get crd clusters.postgresql.cnpg.io >/dev/null || die 'CloudNativePG is not installed.'
  oc get kuadrant "$KUADRANT_NAME" -n "$KUADRANT_NS" >/dev/null || die 'Kuadrant CR missing.'
  local gpupresent
  gpupresent="$(oc get nodes -o json | GPU_KEY="$GPU_SELECTOR_KEY" GPU_VAL="$GPU_SELECTOR_VALUE" python3 -c '
import json,sys,os
print(sum(1 for n in json.load(sys.stdin).get("items",[]) if n["metadata"].get("labels",{}).get(os.environ["GPU_KEY"])==os.environ["GPU_VAL"]))')"
  (( gpupresent > 0 )) || die "No nodes matching $GPU_SELECTOR_KEY=$GPU_SELECTOR_VALUE"
  # A GPU selector shared with another EC2 type would yield a misleading profile.
  oc get nodes -o json | GPU_KEY="$GPU_SELECTOR_KEY" GPU_VAL="$GPU_SELECTOR_VALUE" GPU_TYPE="$GPU_MACHINESET_INSTANCE_TYPE" python3 -c '
import json,sys,os
for n in json.load(sys.stdin).get("items",[]):
 labels=n["metadata"].get("labels",{})
 if labels.get(os.environ["GPU_KEY"]) != os.environ["GPU_VAL"]:continue
 actual=labels.get("node.kubernetes.io/instance-type","")
 if actual and actual!=os.environ["GPU_TYPE"]:
  print("GPU label selects mismatched EC2 instance {}, expected {}".format(actual, os.environ["GPU_TYPE"]),file=sys.stderr);sys.exit(1)
' || die 'GPU label selects an unexpected EC2 instance type'
  log "RHOAI=$rhoai_csv, RHCL=$rhcl_csv, matching GPU nodes=$gpupresent"
  log "MaaS PG namespace=$MAAS_DB_NAMESPACE, API infrastructure=$MAAS_INFRA_NAMESPACE"
  log "Hardware profile=$GPU_HARDWARE_PROFILE_NAME; GPU type from cluster config=${GPU_MACHINESET_INSTANCE_TYPE:-unknown}"
  log 'Preflight passed; no changes without --apply.'
}
enable_uwm() {
  yes "$ENABLE_USER_WORKLOAD_MONITORING" || die 'MaaS requires user-workload monitoring.'
  local existing
  existing="$(oc get configmap cluster-monitoring-config -n openshift-monitoring -o jsonpath='{.data.config\.yaml}' 2>/dev/null || :)"
  # Preserve existing monitoring config; explicitly confirm/reject disabled value.
  if [[ "$existing" == *'enableUserWorkload: false'* ]]; then
    die 'User workload monitoring explicitly disabled in cluster-monitoring-config; adjust manually to preserve your existing monitoring settings.'
  fi
  if [[ -z "$existing" ]]; then
    cat <<'YAML' | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
YAML
  elif [[ "$existing" != *'enableUserWorkload: true'* ]]; then
    # Append only the required flag; don't wipe existing prometheus config.
    local tmp; tmp="$(mktemp)"
    oc get configmap cluster-monitoring-config -n openshift-monitoring -o json | python3 -c '
import json,sys
x=json.load(sys.stdin);x["data"]["config.yaml"]=x.get("data",{}).get("config.yaml","").rstrip()+"\nenableUserWorkload: true\n"
print(json.dumps({"data":x["data"]}))' > "$tmp"
    oc patch configmap cluster-monitoring-config -n openshift-monitoring --type=merge --patch-file "$tmp"
    rm -f "$tmp"
  fi
  wait_for 'user workload monitoring namespace' 1200 20 oc get namespace openshift-user-workload-monitoring
}
create_maas_db() {
  ensure_ns "$MAAS_DB_NAMESPACE"
  ensure_ns "$MAAS_INFRA_NAMESPACE"
  if ! oc get cluster.postgresql.cnpg.io "$MAAS_DB_CLUSTER" -n "$MAAS_DB_NAMESPACE" >/dev/null 2>&1; then
    cat <<YAML | oc apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: $MAAS_DB_CLUSTER
  namespace: $MAAS_DB_NAMESPACE
spec:
  instances: $MAAS_DB_INSTANCES
  bootstrap:
    initdb:
      database: maas
      owner: maas
  storage:
    size: $MAAS_DB_STORAGE_SIZE
    storageClass: $MAAS_DB_STORAGE_CLASS
YAML
  fi
  wait_for 'MaaS CloudNativePG healthy' "$READY_TIMEOUT" 20 check_ready_condition clusters.postgresql.cnpg.io "$MAAS_DB_CLUSTER" "$MAAS_DB_NAMESPACE"
  wait_for 'MaaS PG app secret' 600 10 oc get secret "$MAAS_DB_CLUSTER-app" -n "$MAAS_DB_NAMESPACE"
  # Secret is created only inside the cluster; never printed to the terminal.
  MAAS_DB_NS="$MAAS_DB_NAMESPACE" MAAS_DB_NAME="$MAAS_DB_CLUSTER" MAAS_INFRA_NS="$MAAS_INFRA_NAMESPACE" python3 - <<'PY'
import os,json,subprocess,base64,urllib.parse
ns=os.environ['MAAS_DB_NS'];name=os.environ['MAAS_DB_NAME'];infra=os.environ['MAAS_INFRA_NS']
x=json.loads(subprocess.check_output(['oc','get','secret',name+'-app','-n',ns,'-o','json']))['data']
dec=lambda k:base64.b64decode(x[k]).decode() if k in x else ''
# CNPG-generated secret may contain a short service hostname valid only in its
# own namespace. Always construct the full service DNS for other namespaces.
uri='postgresql://'+urllib.parse.quote(dec('username'),safe='')+':'+urllib.parse.quote(dec('password'),safe='')+'@'+name+'-rw.'+ns+'.svc.cluster.local:5432/maas'
if 'sslmode=' not in uri:uri+=('&' if '?' in uri else '?')+'sslmode=require'
s={'apiVersion':'v1','kind':'Secret','metadata':{'name':'maas-db-config','namespace':infra},'type':'Opaque','stringData':{'DB_CONNECTION_URL':uri}}
subprocess.run(['oc','apply','-f','-'],input=json.dumps(s),text=True,stdout=subprocess.DEVNULL,check=True)
PY
  log "MaaS DB secret provisioned in $MAAS_INFRA_NAMESPACE (credentials not printed)"
}
create_gateway() {
  local host="$GATEWAY_HOST" domain tls_secret="$GATEWAY_TLS_SECRET" ingress_domain
  # Discover the actual default IngressController domain and referenced certificate
  # on every cluster. A static router-certs-default Secret is not guaranteed.
  ingress_domain="$(oc get ingresscontroller default -n openshift-ingress-operator -o jsonpath='{.status.domain}' 2>/dev/null || :)"
  domain="$ingress_domain"
  if [[ -z "$domain" ]]; then
    domain="$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || :)"
  fi
  if [[ -z "$host" ]]; then
    [[ -n "$domain" ]] || die 'Could not determine ingress apps domain; supply GATEWAY_HOST.'
    host="maas.$domain"
  fi
  if [[ -z "$tls_secret" ]]; then
    tls_secret="$(oc get ingresscontroller default -n openshift-ingress-operator -o jsonpath='{.spec.defaultCertificate.name}' 2>/dev/null || :)"
    [[ -n "$tls_secret" ]] || die 'Default IngressController does not reference a custom TLS Secret. Configure one (or set GATEWAY_TLS_SECRET to an existing wildcard certificate in GATEWAY_NAMESPACE).'
  fi
  log "Discovered ingress domain=${domain:-unknown}, gateway host=$host, TLS secret=$GATEWAY_NAMESPACE/$tls_secret"
  # Only a TLS Secret can serve Gateway API certificateRefs, and the Gateway
  # reference is namespace-local. Validate without disclosing the certificate key.
  local secret_type
  secret_type="$(oc get secret "$tls_secret" -n "$GATEWAY_NAMESPACE" -o jsonpath='{.type}' 2>/dev/null || :)"
  [[ "$secret_type" == kubernetes.io/tls ]] || die "TLS secret $GATEWAY_NAMESPACE/$tls_secret missing or not type kubernetes.io/tls"
  # Check certificate hostname when openssl is installed; this catches a stale
  # wildcard certificate when the demo cluster's apps domain changes.
  if command -v openssl >/dev/null 2>&1; then
    local cert_b64
    cert_b64="$(oc get secret "$tls_secret" -n "$GATEWAY_NAMESPACE" -o jsonpath='{.data.tls\.crt}')"
    printf '%s' "$cert_b64" | base64 --decode | openssl x509 -noout -checkhost "$host" | grep -q 'does match certificate' || die "Certificate in $GATEWAY_NAMESPACE/$tls_secret does not cover gateway host $host"
  fi
  oc get gatewayclass "$GATEWAY_CLASS" >/dev/null 2>&1 || {
    if [[ "$GATEWAY_CLASS" != openshift-default ]]; then die "GatewayClass $GATEWAY_CLASS missing; create it or select openshift-default"; fi
    cat <<'YAML' | oc apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: openshift-default
spec:
  controllerName: openshift.io/gateway-controller/v1
YAML
  }
  local existinghost
  existinghost="$(oc get gateway "$GATEWAY_NAME" -n "$GATEWAY_NAMESPACE" -o jsonpath='{.spec.listeners[0].hostname}' 2>/dev/null || :)"
  if [[ -n "$existinghost" && "$existinghost" != "$host" ]]; then
    die "Existing Gateway $GATEWAY_NAME hostname=$existinghost; configured $host. Refusing replacement."
  fi
  oc label namespace "$MAAS_INFRA_NAMESPACE" "${GATEWAY_NAMESPACE_LABEL_PREFIX}${MAAS_TENANT_NAME}=true" --overwrite
  oc get namespace "$MAAS_NAMESPACE" >/dev/null 2>&1 && oc label namespace "$MAAS_NAMESPACE" "${GATEWAY_NAMESPACE_LABEL_PREFIX}${MAAS_TENANT_NAME}=true" --overwrite || :
  if ! oc get gateway "$GATEWAY_NAME" -n "$GATEWAY_NAMESPACE" >/dev/null 2>&1; then
    cat <<YAML | oc apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: $GATEWAY_NAME
  namespace: $GATEWAY_NAMESPACE
  annotations:
    opendatahub.io/managed: "false"
    security.opendatahub.io/authorino-tls-bootstrap: "true"
spec:
  gatewayClassName: $GATEWAY_CLASS
  listeners:
  - name: https
    hostname: "$host"
    port: 443
    protocol: HTTPS
    tls:
      mode: Terminate
      certificateRefs:
      - kind: Secret
        name: $tls_secret
    allowedRoutes:
      kinds:
      - kind: HTTPRoute
      namespaces:
        from: All
YAML
  else
    oc annotate gateway "$GATEWAY_NAME" -n "$GATEWAY_NAMESPACE" opendatahub.io/managed=false security.opendatahub.io/authorino-tls-bootstrap=true --overwrite
  fi
  # A MaaS Gateway serves model HTTPRoutes created later in arbitrary project
  # namespaces. Do not limit attachment to the MaaS infrastructure namespace.
  # Reconcile existing Gateways too, not only newly created ones.
  local listener_names listener_count
  listener_names="$(oc get gateway "$GATEWAY_NAME" -n "$GATEWAY_NAMESPACE" -o jsonpath='{.spec.listeners[*].name}')"
  [[ "$listener_names" == https ]] || die "Gateway $GATEWAY_NAME has unexpected listeners ($listener_names); refusing to patch wrong listener"
  oc patch gateway "$GATEWAY_NAME" -n "$GATEWAY_NAMESPACE" --type=merge \
    -p '{"spec":{"listeners":[{"name":"https","hostname":"'"$host"'","port":443,"protocol":"HTTPS","tls":{"mode":"Terminate","certificateRefs":[{"kind":"Secret","name":"'"$tls_secret"'"}]},"allowedRoutes":{"kinds":[{"kind":"HTTPRoute"}],"namespaces":{"from":"All"}}}]}}'
  local allowed_from
  allowed_from="$(oc get gateway "$GATEWAY_NAME" -n "$GATEWAY_NAMESPACE" -o jsonpath='{.spec.listeners[0].allowedRoutes.namespaces.from}')"
  [[ "$allowed_from" == All ]] || die "Gateway namespace attachment policy did not reconcile to All"
  log "Gateway hostname: $host; HTTPRoutes accepted from all namespaces (MaaS auth policies remain configured)"
}
configure_authorino_tls() {
  wait_for 'Authorino service' 1200 15 oc get service authorino-authorino-authorization -n "$KUADRANT_NS"
  wait_for 'Authorino CR' 1200 15 oc get authorino authorino -n "$KUADRANT_NS"
  oc annotate service authorino-authorino-authorization -n "$KUADRANT_NS" service.beta.openshift.io/serving-cert-secret-name=authorino-server-cert --overwrite
  wait_for 'Authorino service-serving certificate' 600 10 oc get secret authorino-server-cert -n "$KUADRANT_NS"
  oc patch authorino authorino -n "$KUADRANT_NS" --type=merge -p '{"spec":{"listener":{"tls":{"enabled":true,"certSecretRef":{"name":"authorino-server-cert"}}}}}'
  oc set env deployment/authorino -n "$KUADRANT_NS" \
    SSL_CERT_FILE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt \
    REQUESTS_CA_BUNDLE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt
  oc annotate gateway "$GATEWAY_NAME" -n "$GATEWAY_NAMESPACE" security.opendatahub.io/authorino-tls-bootstrap=true --overwrite
}
activate_maas() {
  # Preserve existing DSC spec, modify only MaaS/OGX subtree. Do not write legacy kserve.modelsAsService.
  local ogx=Removed
  yes "$ENABLE_GEN_AI_STUDIO" && ogx=Managed
  oc patch dsc "$DSC_NAME" --type=merge -p "{\"spec\":{\"components\":{\"aigateway\":{\"managementState\":\"Managed\",\"modelsAsAService\":{\"managementState\":\"Managed\"}},\"ogx\":{\"managementState\":\"$ogx\"},\"kserve\":{\"rawDeploymentServiceConfig\":\"Headed\"}}}}"
  wait_crd maastenantconfigs.maas.opendatahub.io
  # Legacy model serving UI requires this flag for vLLM TP; no default model is deployed.
  wait_for 'ODH DashboardConfig CR' 1200 15 oc get odhdashboardconfig odh-dashboard-config -n redhat-ods-applications
  oc patch odhdashboardconfig odh-dashboard-config -n redhat-ods-applications --type=merge -p "{\"spec\":{\"dashboardConfig\":{\"modelAsService\":true,\"genAiStudio\":true,\"vLLMDeploymentOnMaaS\":$(yes "$ENABLE_VLLM_DEPLOYMENT_ON_MAAS" && echo true || echo false),\"observabilityDashboard\":true,\"externalModels\":true}}}"
  wait_for 'MaaS modelsAsAService readiness' "$READY_TIMEOUT" 25 maas_dsc_condition
  wait_for 'MaaS Tenant Ready' "$READY_TIMEOUT" 25 maas_tenant_ready
}
ensure_gateway_route() {
  # Prefer OpenShift's generated Route; only create fallback if controller has not done so.
  local routes svc host
  routes="$(oc get route -n "$GATEWAY_NAMESPACE" -l "gateway.networking.k8s.io/gateway-name=$GATEWAY_NAME" -o json | python3 -c 'import json,sys;print(len(json.load(sys.stdin).get("items",[])))')"
  if (( routes > 0 )); then log "Gateway already has $routes controller-managed Route(s)"; return; fi
  svc="$(oc get svc -n "$GATEWAY_NAMESPACE" -l "gateway.networking.k8s.io/gateway-name=$GATEWAY_NAME" -o json | python3 -c 'import json,sys;x=json.load(sys.stdin).get("items",[]);print(x[0]["metadata"]["name"] if x else "")')"
  if [[ -z "$svc" ]]; then warn 'Gateway has no automatically generated Route or labeled Service yet; external route validation requires manual follow-up'; return; fi
  host="$(oc get gateway "$GATEWAY_NAME" -n "$GATEWAY_NAMESPACE" -o jsonpath='{.spec.listeners[0].hostname}')"
  if oc get route "${GATEWAY_NAME}-gateway" -n "$GATEWAY_NAMESPACE" >/dev/null 2>&1; then return; fi
  cat <<YAML | oc apply -f -
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: ${GATEWAY_NAME}-gateway
  namespace: $GATEWAY_NAMESPACE
spec:
  host: "$host"
  to:
    kind: Service
    name: $svc
    weight: 100
  port:
    targetPort: https
  tls:
    termination: reencrypt
    insecureEdgeTerminationPolicy: Redirect
YAML
}
create_gpu_profile() {
  yes "$CREATE_GPU_HARDWARE_PROFILE" || return
  wait_crd hardwareprofiles.infrastructure.opendatahub.io
  # Hardware profile resources from RHOAI 3.5 dashboard API; no changes to InferenceServices.
  local existing
  existing="$(oc get hardwareprofile.infrastructure.opendatahub.io "$GPU_HARDWARE_PROFILE_NAME" -n redhat-ods-applications -o jsonpath='{.metadata.name}' 2>/dev/null || :)"
  if [[ -n "$existing" ]]; then
    # Do not silently reuse a HardwareProfile targeting a different GPU pool.
    oc get hardwareprofile.infrastructure.opendatahub.io "$GPU_HARDWARE_PROFILE_NAME" -n redhat-ods-applications -o json | \
      GPU_KEY="$GPU_SELECTOR_KEY" GPU_VAL="$GPU_SELECTOR_VALUE" GPU_TYPE="$GPU_MACHINESET_INSTANCE_TYPE" python3 -c '
import json,sys,os
s=json.load(sys.stdin).get("spec",{}).get("scheduling",{}).get("node",{}).get("nodeSelector",{})
if s.get(os.environ["GPU_KEY"])!=os.environ["GPU_VAL"] or s.get("node.kubernetes.io/instance-type")!=os.environ["GPU_TYPE"]:
 print("Existing GPU HardwareProfile has a different node selector; inspect manually",file=sys.stderr);sys.exit(1)' \
      || die 'GPU HardwareProfile exists with a mismatched node selector.'
    log "HardwareProfile $GPU_HARDWARE_PROFILE_NAME already exists and targets the configured EC2 type; preserving limits"
    return
  fi
  cat <<YAML | oc apply -f -
apiVersion: infrastructure.opendatahub.io/v1
kind: HardwareProfile
metadata:
  name: $GPU_HARDWARE_PROFILE_NAME
  namespace: redhat-ods-applications
  annotations:
    openshift.io/display-name: "$GPU_HARDWARE_PROFILE_DISPLAY_NAME"
    opendatahub.io/dashboard-feature-visibility: '["model-serving"]'
spec:
  identifiers:
  - identifier: cpu
    displayName: CPU
    resourceType: CPU
    defaultCount: $GPU_PROFILE_CPU_DEFAULT
    minCount: 1
    maxCount: $GPU_PROFILE_CPU_MAX
  - identifier: memory
    displayName: Memory
    resourceType: Memory
    defaultCount: $GPU_PROFILE_MEMORY_DEFAULT
    minCount: 2Gi
    maxCount: $GPU_PROFILE_MEMORY_MAX
  - identifier: nvidia.com/gpu
    displayName: NVIDIA GPU
    resourceType: Accelerator
    defaultCount: $GPU_PROFILE_GPU_DEFAULT
    minCount: 1
    maxCount: $GPU_PROFILE_GPU_MAX
  scheduling:
    type: Node
    node:
      nodeSelector:
        $GPU_SELECTOR_KEY: "$GPU_SELECTOR_VALUE"
        node.kubernetes.io/instance-type: "$GPU_MACHINESET_INSTANCE_TYPE"
      tolerations:
      - key: $GPU_TAINT_KEY
        operator: Equal
        value: "$GPU_TAINT_VALUE"
        effect: $GPU_TAINT_EFFECT
YAML
}
print_summary() {
  log 'MaaS checks:'
  oc get dsc "$DSC_NAME"
  oc get gateway "$GATEWAY_NAME" -n "$GATEWAY_NAMESPACE"
  oc get maastenantconfig.maas.opendatahub.io "$MAAS_TENANT_NAME" -n "$MAAS_NAMESPACE"
  oc get maastenantconfig "$MAAS_TENANT_NAME" -n "$MAAS_NAMESPACE" -o jsonpath='{.status.infraNamespace}{"\n"}' || :
  oc get deployment maas-api -n "$MAAS_INFRA_NAMESPACE" || :
  oc get hardwareprofile.infrastructure.opendatahub.io "$GPU_HARDWARE_PROFILE_NAME" -n redhat-ods-applications || :
  log 'No model or MaaS subscription was created. Deploy an LLMInferenceService and configure API keys/policies next.'
}
main() {
  preflight
  [[ "$MODE" == apply ]] || return 0
  enable_uwm
  create_maas_db
  create_gateway
  configure_authorino_tls
  activate_maas
  ensure_gateway_route
  create_gpu_profile
  print_summary
  log 'MaaS setup complete (subject to successful real-cluster validation).'
}
main "$@"
