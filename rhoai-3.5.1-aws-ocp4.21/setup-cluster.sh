#!/usr/bin/env bash
# RHOAI 3.5.x / AWS OpenShift 4.21+ baseline. Run: bash setup-cluster.sh --apply
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/setup-cluster.conf"
MODE=check
for a in "$@"; do case "$a" in --apply) MODE=apply;; --check) MODE=check;; config=*) CONFIG_FILE="${a#config=}";; *) echo "Usage: bash setup-cluster.sh [--check|--apply] [config=FILE]" >&2; exit 2;; esac; done
[[ -f "$CONFIG_FILE" ]] || { echo "Missing config $CONFIG_FILE" >&2; exit 1; }
# shellcheck source=setup-cluster.conf
source "$CONFIG_FILE"
# shellcheck source=rhoai-common.sh
source "$SCRIPT_DIR/rhoai-common.sh"
trap 'warn "Failed at line $LINENO (exit code $?). Check the preceding command and cluster events."' ERR

# Classify control-plane, GPU and worker roles from actual Node data.
worker_count() {
  oc get nodes -o json | GPU_KEY="$GPU_SELECTOR_KEY" python3 -c '
import json,os,sys
items=json.load(sys.stdin).get("items",[]); n=0
for x in items:
 m=x["metadata"]; labels=m.get("labels",{}); spec=x.get("spec",{}); status=x.get("status",{})
 if "node-role.kubernetes.io/worker" not in labels: continue
 if "node-role.kubernetes.io/master" in labels or "node-role.kubernetes.io/control-plane" in labels: continue
 if os.environ["GPU_KEY"] in labels: continue
 if spec.get("unschedulable"): continue
 if any(z.get("type")=="Ready" and z.get("status")=="True" for z in status.get("conditions",[])): n+=1
print(n)'
}
# Select AWS worker MachineSet; do not select GPU, master, infra or custom pool.
select_worker_ms() {
  local preferred="${1:-}"
  if [[ -n "$preferred" ]]; then oc get machineset -n openshift-machine-api "$preferred" >/dev/null || die "Missing MachineSet $preferred"; printf '%s\n' "$preferred"; return; fi
  oc get machinesets -n openshift-machine-api -o json | python3 -c '
import json,sys
items=json.load(sys.stdin).get("items",[])
for x in sorted(items,key=lambda a:a["metadata"]["name"]):
 name=x["metadata"]["name"]; t=x.get("spec",{}).get("template",{}); labels=t.get("metadata",{}).get("labels",{}); ml=x["metadata"].get("labels",{})
 role=ml.get("machine.openshift.io/cluster-api-machine-role",labels.get("machine.openshift.io/cluster-api-machine-role",""))
 if role!="worker" or "gpu.openshift.ai/accelerator" in labels or "-gpu" in name:continue
 print(name);sys.exit(0)
sys.exit(1)' || die 'No standard AWS worker MachineSet exists; specify WORKER_MACHINESET_SOURCE_NAME.'
}
worker_desired_count() {
  oc get machinesets -n openshift-machine-api -o json | GPU_KEY="$GPU_SELECTOR_KEY" python3 -c '
import json,os,sys
s=0
for x in json.load(sys.stdin).get("items",[]):
 t=x.get("spec",{}).get("template",{}); l=t.get("metadata",{}).get("labels",{}); meta=x["metadata"].get("labels",{})
 role=meta.get("machine.openshift.io/cluster-api-machine-role",l.get("machine.openshift.io/cluster-api-machine-role",""))
 if role!="worker" or os.environ["GPU_KEY"] in l or "-gpu" in x["metadata"]["name"]:continue
 s+=int(x.get("spec",{}).get("replicas",0) or 0)
print(s)'
}
scale_cpu_workers() {
  local ready desired deficit source replicas
  ready="$(worker_count)"; desired="$(worker_desired_count)"
  log "CPU workers: $ready Ready / $desired MachineSet-desired / minimum $MIN_READY_WORKERS"
  if (( ready >= MIN_READY_WORKERS )); then log 'CPU worker minimum already satisfied; nothing to scale'; return; fi
  if (( desired < MIN_READY_WORKERS )); then
    deficit=$((MIN_READY_WORKERS-desired))
    source="$(select_worker_ms "$WORKER_MACHINESET_SOURCE_NAME")"
    replicas="$(oc get machineset -n openshift-machine-api "$source" -o jsonpath='{.spec.replicas}')"
    log "Scaling existing worker MachineSet $source from $replicas to $((replicas+deficit)) (no CPU instance-type/volume edits)"
    oc scale machineset "$source" -n openshift-machine-api --replicas="$((replicas+deficit))"
  else
    log "Worker MachineSets already request $desired; awaiting missing Ready workers without further scaling"
  fi
  wait_for 'minimum Ready CPU worker count' "$WORKER_WAIT_SECONDS" 30 worker_min_satisfied
}
worker_min_satisfied() { (( $(worker_count) >= MIN_READY_WORKERS )); }
# AWS MachineSet cloning retains placement/subnet/credentials from a real worker.
make_gpu_machineset() {
  yes "$GPU_ENABLED" || return 0
  local source name current
  source="$(select_worker_ms "${GPU_MACHINESET_SOURCE_NAME:-$WORKER_MACHINESET_SOURCE_NAME}")"
  name="${GPU_MACHINESET_NAME:-${source}-gpu}"
  if oc get machineset "$name" -n openshift-machine-api >/dev/null 2>&1; then
    current="$(oc get machineset "$name" -n openshift-machine-api -o jsonpath='{.spec.template.spec.providerSpec.value.instanceType}')"
    [[ "$current" == "$GPU_MACHINESET_INSTANCE_TYPE" ]] || die "Existing GPU MachineSet $name is $current, configured $GPU_MACHINESET_INSTANCE_TYPE; refusing mutation"
    log "Reusing GPU MachineSet $name"
    oc scale machineset "$name" -n openshift-machine-api --replicas="$GPU_MACHINESET_REPLICAS"
  else
    log "Cloning $source into GPU MachineSet $name using $GPU_MACHINESET_INSTANCE_TYPE"
    oc get machineset "$source" -n openshift-machine-api -o json | \
      GPU_NAME="$name" GPU_REPLICAS="$GPU_MACHINESET_REPLICAS" GPU_TYPE="$GPU_MACHINESET_INSTANCE_TYPE" \
      GPU_DISK="$GPU_MACHINESET_ROOT_VOLUME_SIZE_GB" GPU_LABEL_KEY="$GPU_SELECTOR_KEY" GPU_LABEL_VAL="$GPU_SELECTOR_VALUE" \
      GPU_TAINT_KEY="$GPU_TAINT_KEY" GPU_TAINT_VAL="$GPU_TAINT_VALUE" GPU_TAINT_EFFECT="$GPU_TAINT_EFFECT" \
      python3 -c '
import json,os,sys
x=json.load(sys.stdin);m=x["metadata"]
for k in ("uid","resourceVersion","creationTimestamp","managedFields","generation","ownerReferences","annotations"):m.pop(k,None)
x.pop("status",None);name=os.environ["GPU_NAME"]; m["name"]=name
m.setdefault("labels",{})["machine.openshift.io/cluster-api-machineset"]=name
x["spec"]["replicas"]=int(os.environ["GPU_REPLICAS"])
x["spec"]["selector"]["matchLabels"]["machine.openshift.io/cluster-api-machineset"]=name
t=x["spec"]["template"]
t["metadata"].setdefault("labels",{})["machine.openshift.io/cluster-api-machineset"]=name
t["metadata"]["labels"][os.environ["GPU_LABEL_KEY"]]=os.environ["GPU_LABEL_VAL"]
t["metadata"]["labels"]["node-role.kubernetes.io/gpu"]=""
s=t["spec"];s["taints"]=[{"key":os.environ["GPU_TAINT_KEY"],"value":os.environ["GPU_TAINT_VAL"],"effect":os.environ["GPU_TAINT_EFFECT"]}]
p=s["providerSpec"]["value"];p["instanceType"]=os.environ["GPU_TYPE"]
if p.get("blockDevices"):
 p["blockDevices"][0].setdefault("ebs",{})["volumeSize"]=int(os.environ["GPU_DISK"])
print(json.dumps(x))' | oc apply -f -
  fi
  GPU_ACTIVE_MACHINESET="$name"
  wait_for "GPU MachineSet $name ready replicas" "$GPU_WAIT_SECONDS" 30 gpu_ms_ready "$name"
  # Reconcile Node labels/taints through Machine.status.nodeRef, also on reruns.
  label_gpu_nodes "$name"
  wait_for 'GPU allocatable resource available' "$GPU_WAIT_SECONDS" 45 gpu_allocatable
}
gpu_ms_ready() { [[ "$(oc get machineset "$1" -n openshift-machine-api -o jsonpath='{.status.readyReplicas}' 2>/dev/null || :)" == "$GPU_MACHINESET_REPLICAS" ]]; }
label_gpu_nodes() {
  local name="$1" node
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    oc label node "$node" "$GPU_SELECTOR_KEY=$GPU_SELECTOR_VALUE" 'node-role.kubernetes.io/gpu=' --overwrite
    oc adm taint node "$node" "$GPU_TAINT_KEY=$GPU_TAINT_VALUE:$GPU_TAINT_EFFECT" --overwrite
  done < <(oc get machines -n openshift-machine-api -l "machine.openshift.io/cluster-api-machineset=$name" -o json | python3 -c 'import json,sys;[print(m.get("status",{}).get("nodeRef",{}).get("name","")) for m in json.load(sys.stdin).get("items",[])]')
}
gpu_allocatable() {
  oc get nodes -o json | GPU_KEY="$GPU_SELECTOR_KEY" GPU_VAL="$GPU_SELECTOR_VALUE" python3 -c '
import json,os,sys
for n in json.load(sys.stdin).get("items",[]):
 if n["metadata"].get("labels",{}).get(os.environ["GPU_KEY"]) != os.environ["GPU_VAL"]:continue
 if int(n.get("status",{}).get("allocatable",{}).get("nvidia.com/gpu","0"))>0:sys.exit(0)
sys.exit(1)'
}
# Inspect OpenShift OAuth, not merely whether Keycloak pods are installed.
# Keycloak must be configured as an OpenID identity provider for the cluster.
inspect_identity_provider() {
  case "$IDENTITY_PROVIDER_MODE" in
    keycloak)
      oc get oauth cluster -o json | EXPECTED_IDP="$KEYCLOAK_OAUTH_IDP_NAME" python3 -c '
import json,os,sys
providers=json.load(sys.stdin).get("spec",{}).get("identityProviders",[])
openid=[p for p in providers if p.get("type")=="OpenID"]
expected=os.environ.get("EXPECTED_IDP","")
if expected: openid=[p for p in openid if p.get("name")==expected]
if not openid:
  print("No matching OpenID identity provider in OAuth/cluster. Keycloak installed alone is not enough.",file=sys.stderr)
  print("Available OAuth identity providers: "+", ".join(str(p.get("name","?"))+" ("+str(p.get("type","?"))+")" for p in providers),file=sys.stderr)
  sys.exit(1)
print("Configured OpenID identity provider(s): "+", ".join(p["name"] for p in openid))' || die 'Expected Keycloak-backed OpenID provider not found; refusing to create HTPasswd automatically. Verify OAuth/cluster or use IDENTITY_PROVIDER_MODE=preserve when appropriate.'
      ;;
    preserve)
      log 'Preserving all existing OpenShift identity providers; no OAuth changes.'
      ;;
    htpasswd)
      [[ -f "$HTPASSWD_PATH" ]] || die "HTPASSWD_PATH does not exist: $HTPASSWD_PATH"
      log "Explicit HTPasswd provisioning requested for provider $HTPASSWD_IDP"
      ;;
    *) die "IDENTITY_PROVIDER_MODE must be keycloak, preserve or htpasswd (got '$IDENTITY_PROVIDER_MODE')" ;;
  esac
}
configure_htpasswd() {
  [[ "$IDENTITY_PROVIDER_MODE" == htpasswd ]] || { log 'Reusing existing OAuth configuration; HTPasswd not installed or modified'; return; }
  [[ -f "$HTPASSWD_PATH" ]] || die "HTPASSWD_PATH does not exist: $HTPASSWD_PATH"
  oc create secret generic "$HTPASSWD_SECRET" -n openshift-config --from-file="htpasswd=$HTPASSWD_PATH" --dry-run=client -o yaml | oc apply -f -
  # Use tempfile to avoid command substitutions with heredocs (Mac bash safe).
  local tmp; tmp="$(mktemp)"
  oc get oauth cluster -o json | HTPASSWD_SECRET="$HTPASSWD_SECRET" HTPASSWD_IDP="$HTPASSWD_IDP" python3 -c '
import json,os,sys
x=json.load(sys.stdin);p=x.get("spec",{}).get("identityProviders",[]);name=os.environ["HTPASSWD_IDP"]
new={"name":name,"mappingMethod":"claim","type":"HTPasswd","htpasswd":{"fileData":{"name":os.environ["HTPASSWD_SECRET"]}}}
print(json.dumps({"spec":{"identityProviders":[v for v in p if v["name"]!=name]+[new]}}))' > "$tmp"
  oc patch oauth cluster --type=merge --patch-file "$tmp"; rm -f "$tmp"
  oc adm policy add-cluster-role-to-user cluster-admin "$ADMIN_USER"
}
# Create an instance of optional LWS and JobSet operators when their CRDs are available.
create_operator_instance() {
  local kind="$1" ns="$2" name="$3" crd api
  crd="$(oc get crd -o json | KIND="$kind" python3 -c '
import json,os,sys
for x in json.load(sys.stdin).get("items",[]):
 if x.get("spec",{}).get("names",{}).get("kind")==os.environ["KIND"]:print(x["metadata"]["name"]);sys.exit(0)
sys.exit(1)' || :)"
  [[ -n "$crd" ]] || { warn "No $kind CRD; inspect Operator installation."; return 0; }
  api="$(oc get crd "$crd" -o json | python3 -c 'import json,sys; x=json.load(sys.stdin)["spec"]; print(x["group"]+"/"+next(z["name"] for z in x["versions"] if z.get("served")))')"
  cat <<YAML | oc apply -f -
apiVersion: $api
kind: $kind
metadata:
  name: $name
  namespace: $ns
spec:
  managementState: Managed
YAML
}
install_prereqs() {
  yes "$CERT_MANAGER_ENABLED" && { ensure_olm openshift-cert-manager-operator cert-manager-operator stable-v1 redhat-operators own; wait_crd certificates.cert-manager.io; }
  if yes "$RHCL_ENABLED"; then
    ensure_olm rhcl-operator openshift-operators "$RHCL_CHANNEL" redhat-operators all '' "$RHCL_EXPECTED_CSV_REGEX"
    wait_crd kuadrants.kuadrant.io
    ensure_ns kuadrant-system
    if ! oc get kuadrant kuadrant -n kuadrant-system >/dev/null 2>&1; then
      cat <<'YAML' | oc apply -f -
apiVersion: kuadrant.io/v1beta1
kind: Kuadrant
metadata:
  name: kuadrant
  namespace: kuadrant-system
spec: {}
YAML
    fi
  fi
  if yes "$LWS_ENABLED"; then
    ensure_olm leader-worker-set openshift-lws-operator stable-v1.0 redhat-operators own
    create_operator_instance LeaderWorkerSetOperator openshift-lws-operator cluster
  fi
  if yes "$JOBSET_ENABLED"; then
    ensure_olm job-set openshift-jobset-operator stable-v1.0 redhat-operators own
    create_operator_instance JobSetOperator openshift-jobset-operator cluster
  fi
  yes "$PIPELINES_ENABLED" && ensure_olm openshift-pipelines-operator-rh openshift-operators latest redhat-operators all
  yes "$SERVICEMESH3_ENABLED" && ensure_olm servicemeshoperator3 openshift-operators stable redhat-operators all
  yes "$CNPG_ENABLED" && { ensure_olm cloudnative-pg openshift-operators stable-v1 certified-operators all; wait_crd clusters.postgresql.cnpg.io; }
  yes "$ODF_ENABLED" && { ensure_olm odf-operator openshift-storage "$ODF_CHANNEL" redhat-operators own; wait_crd noobaas.noobaa.io; }
  if yes "$NFD_ENABLED"; then
    ensure_olm nfd openshift-nfd stable redhat-operators own
    wait_crd nodefeaturediscoveries.nfd.openshift.io
    cat <<'YAML' | oc apply -f -
apiVersion: nfd.openshift.io/v1
kind: NodeFeatureDiscovery
metadata:
  name: nfd-instance
  namespace: openshift-nfd
spec:
  operand:
    imagePullPolicy: IfNotPresent
  workerConfig:
    configData: |
      core:
        sleepInterval: 60s
      sources:
        pci:
          deviceClassWhitelist: ["02", "03", "0200", "0207", "0300", "0302"]
          deviceLabelFields: ["vendor"]
YAML
  fi
  if yes "$NVIDIA_ENABLED"; then
    ensure_olm gpu-operator-certified nvidia-gpu-operator stable certified-operators own
    wait_crd clusterpolicies.nvidia.com
    if ! oc get clusterpolicy gpu-cluster-policy >/dev/null 2>&1; then
      cat <<'YAML' | oc apply -f -
apiVersion: nvidia.com/v1
kind: ClusterPolicy
metadata:
  name: gpu-cluster-policy
spec:
  operator:
    defaultRuntime: crio
    use_ocp_driver_toolkit: true
  daemonsets: {}
  driver: {enabled: true}
  toolkit: {enabled: true}
  devicePlugin: {enabled: true}
  dcgm: {enabled: true}
  dcgmExporter: {enabled: true}
  gfd: {enabled: true}
  migManager: {enabled: true}
  nodeStatusExporter: {enabled: true}
  validator:
    plugin:
      env:
      - name: WITH_WORKLOAD
        value: "true"
YAML
    fi
  fi
}
# Enable the console plugin exactly as the ODF installation wizard does.
# Preserve other installed console plugins (networking, monitoring, etc.).
enable_odf_console() {
  yes "$ODF_ENABLED" || return 0
  wait_for 'ODF ConsolePlugin resource' 300 10 oc get consoleplugin odf-console
  python3 - <<'PYCONSOLE'
import json
import subprocess

current = json.loads(subprocess.check_output(
    ['oc', 'get', 'console.operator.openshift.io', 'cluster', '-o', 'json'], text=True))
plugins = current.get('spec', {}).get('plugins') or []
if 'odf-console' not in plugins:
    patch = [{'op': 'add', 'path': '/spec/plugins' if 'plugins' not in current.get('spec', {}) else '/spec/plugins/-',
              'value': plugins + ['odf-console'] if 'plugins' not in current.get('spec', {}) else 'odf-console'}]
    subprocess.run(['oc', 'patch', 'console.operator.openshift.io', 'cluster',
                    '--type=json', '-p', json.dumps(patch)], check=True)
print('Enabled console plugins:', ', '.join(plugins + (['odf-console'] if 'odf-console' not in plugins else [])))
PYCONSOLE
}
# Version-matched ODF standalone MCG is provisioned by StorageCluster, NOT a direct NooBaa CR.
# Its default AWS backing store requires a cloud credentials Secret supplied by CCO
# (or provisioned as documented by the cluster administrator for manual/STS modes).
check_mcg_storagecluster() {
  oc get storagecluster ocs-storagecluster -n openshift-storage -o json | python3 -c '
import json,sys
obj=json.load(sys.stdin)
m=obj.get("spec",{}).get("multiCloudGateway",{})
sys.exit(0 if m.get("reconcileStrategy")=="standalone" else 1)'
}
mcg_credential_diagnostics() {
  local msg
  msg="$(oc get noobaa noobaa -n openshift-storage -o json 2>/dev/null | python3 -c '
import json,sys
try:
  obj=json.load(sys.stdin)
  for c in obj.get("status",{}).get("conditions",[]):
    if c.get("type")=="Available" and c.get("status")!="True":
      print(c.get("message",""))
except Exception:pass' || :)"
  [[ -n "$msg" ]] && warn "NooBaa Available=False: $msg"
  if [[ "$msg" == *noobaa-aws-cloud-creds-secret* ]]; then
    warn 'NooBaa is blocked on AWS cloud credentials. Inspect CredentialsRequests in ALL namespaces and Cloud Credential Operator mode; do not create arbitrary AWS credentials.'
    oc get credentialsrequests.cloudcredential.openshift.io -A 2>/dev/null | grep -E '(^NAMESPACE|noobaa)' >&2 || :
    oc get cloudcredentials.operator.openshift.io cluster -o jsonpath='CloudCredentialMode={.spec.credentialsMode}{"\n"}' >&2 2>/dev/null || :
  fi
}
mcg_ready() {
  [[ "$(oc get noobaa noobaa -n openshift-storage -o jsonpath='{.status.phase}' 2>/dev/null || :)" == Ready ]] || return 1
  [[ "$(oc get noobaa noobaa -n openshift-storage -o json | python3 -c '
import json,sys
x=json.load(sys.stdin)
print(next((c.get("status","") for c in x.get("status",{}).get("conditions",[]) if c.get("type")=="Available"),""))')" == True ]]
}
wait_mcg() {
  local start=$SECONDS interval=20 reported=0
  until mcg_ready; do
    if (( SECONDS - start >= MCG_CREDENTIAL_WAIT_SECONDS )) && (( reported == 0 )); then
      mcg_credential_diagnostics
      reported=1
      if [[ "$(oc get noobaa noobaa -n openshift-storage -o jsonpath='{.status.conditions[?(@.type=="Available")].message}' 2>/dev/null || :)" == *noobaa-aws-cloud-creds-secret* ]]; then
        die "NooBaa AWS cloud credential secret still missing after ${MCG_CREDENTIAL_WAIT_SECONDS}s. Check OpenShift Cloud Credential Operator configuration, CredentialsRequests and AWS permissions. Installation paused without deleting any resources."
      fi
    fi
    if (( SECONDS - start >= READY_TIMEOUT )); then
      mcg_credential_diagnostics
      die 'Timeout: standalone MCG did not become Ready; see oc describe noobaa noobaa -n openshift-storage.'
    fi
    log "Waiting for ODF standalone MCG / NooBaa Ready (${SECONDS-start} elapsed)"
    sleep "$interval"
  done
  log 'Ready: ODF standalone MCG and NooBaa'
}
provision_mcg() {
  yes "$NOOBAA_ENABLED" || return 0
  yes "$ODF_ENABLED" || die 'NOOBAA_ENABLED requires ODF_ENABLED'
  oc get storageclass "$NOOBAA_STORAGE_CLASS" >/dev/null || die "Missing NooBaa database StorageClass $NOOBAA_STORAGE_CLASS"
  wait_crd storageclusters.ocs.openshift.io
  # ODF permits a single StorageCluster per installation. Never overwrite one
  # with a different name or mutate a full Ceph deployment.
  local names
  names="$(oc get storagecluster -n openshift-storage -o json | python3 -c 'import json,sys;print(" ".join(i["metadata"]["name"] for i in json.load(sys.stdin).get("items",[])))')"
  if [[ -n "$names" && "$names" != ocs-storagecluster ]]; then
    die "Unexpected existing ODF StorageCluster(s): $names. Refusing to install another one."
  fi
  if oc get noobaa noobaa -n openshift-storage >/dev/null 2>&1 && [[ -z "$names" ]]; then
    die 'Direct NooBaa exists without a StorageCluster. Use reset-odf-lab.sh for a disposable lab reset before installation.'
  fi
  if [[ "$names" == ocs-storagecluster ]]; then
    check_mcg_storagecluster || die 'Existing ocs-storagecluster is not standalone MCG; refusing to modify it.'
    local sc
    sc="$(oc get storagecluster ocs-storagecluster -n openshift-storage -o jsonpath='{.spec.multiCloudGateway.dbStorageClassName}')"
    [[ "$sc" == "$NOOBAA_STORAGE_CLASS" ]] || die "Existing MCG database StorageClass is '$sc', expected '$NOOBAA_STORAGE_CLASS'."
    log 'Reusing existing standalone MCG StorageCluster'
  else
    log 'Creating ODF $ODF_CHANNEL standalone MCG StorageCluster (ODF Operator owns NooBaa lifecycle)'
    cat <<YAML | oc apply -f -
apiVersion: ocs.openshift.io/v1
kind: StorageCluster
metadata:
  name: ocs-storagecluster
  namespace: openshift-storage
spec:
  resourceProfile: lean
  multiCloudGateway:
    reconcileStrategy: standalone
    dbStorageClassName: $NOOBAA_STORAGE_CLASS
YAML
  fi
  wait_for 'ODF Operator to create NooBaa custom resource' "${MCG_RESOURCE_WAIT_SECONDS:-600}" 15 oc get noobaa noobaa -n openshift-storage
  wait_mcg
  # The provisioner and default bucket class must be owned by the Operators.
  wait_for 'ODF ObjectBucket StorageClass' 600 15 oc get storageclass openshift-storage.noobaa.io
  wait_crd objectbucketclaims.objectbucket.io
  oc get storageclass openshift-storage.noobaa.io -o json | python3 -c '
import json,sys
sc=json.load(sys.stdin)
expected="openshift-storage.noobaa.io/obc"
actual=sc.get("provisioner","")
if actual!=expected:
 print("Unexpected NooBaa ObjectBucket StorageClass provisioner: "+actual,file=sys.stderr)
 sys.exit(1)'
  log 'ODF standalone MCG: ready; ObjectBucket provisioning available.'
}

# RHOAI 3.5 managed observability uses COO, Tempo and OpenTelemetry CRDs.
install_observability_operators() {
  yes "$ENABLE_RHOAI_OBSERVABILITY" || return 0
  ensure_ns openshift-cluster-observability-operator
  oc label namespace openshift-cluster-observability-operator openshift.io/cluster-monitoring=true --overwrite >/dev/null
  ensure_olm cluster-observability-operator openshift-cluster-observability-operator "$COO_CHANNEL" redhat-operators all
  ensure_olm opentelemetry-product openshift-opentelemetry-operator "$OTEL_CHANNEL" redhat-operators all
  ensure_olm tempo-product openshift-tempo-operator "$TEMPO_CHANNEL" redhat-operators all
  wait_crd monitoringstacks.monitoring.rhobs
  wait_crd opentelemetrycollectors.opentelemetry.io
  wait_crd tempomonolithics.tempo.grafana.com
}

configure_rhoai_observability() {
  yes "$ENABLE_RHOAI_OBSERVABILITY" || return 0
  local obs_changed=false
  # New MonitoringStack is a reliable signal that this is an initial observability rollout.
  if ! oc get monitoringstack data-science-monitoringstack -n "$OBS_NAMESPACE" >/dev/null 2>&1; then
    obs_changed=true
  fi
  local trace_block=''
  if yes "$ENABLE_RHOAI_TRACING"; then
    trace_block=$(cat <<YAML
    "traces": {
      "sampleRatio": "$OBS_TRACE_SAMPLE_RATIO",
      "storage": {"backend":"pv", "retention":"$OBS_TRACE_RETENTION"},
      "exporters": {}
    }
YAML
)
  fi
  # Merge patch preserves all unrelated DSCI settings, including trusted CA.
  local patch
  patch=$(OBS_NS="$OBS_NAMESPACE" OBS_METRIC_SIZE="$OBS_METRICS_SIZE" OBS_METRIC_RETENTION="$OBS_METRICS_RETENTION" OBS_PROM_REPLICAS="$OBS_PROMETHEUS_REPLICAS" ENABLE_ALERTS="$ENABLE_RHOAI_ALERTING" ENABLE_TRACES="$ENABLE_RHOAI_TRACING" TRACE_SAMPLE="$OBS_TRACE_SAMPLE_RATIO" TRACE_RETENTION="$OBS_TRACE_RETENTION" python3 - <<'PYOBS'
import json,os
m={"managementState":"Managed", "namespace":os.environ["OBS_NS"],
   "metrics":{"replicas":int(os.environ["OBS_PROM_REPLICAS"]),"storage":{"size":os.environ["OBS_METRIC_SIZE"],"retention":os.environ["OBS_METRIC_RETENTION"]},"exporters":{}}}
if os.environ["ENABLE_ALERTS"].lower() in ("true","yes","1"):m["alerting"]={}
if os.environ["ENABLE_TRACES"].lower() in ("true","yes","1"):
 m["traces"]={"sampleRatio":os.environ["TRACE_SAMPLE"],"storage":{"backend":"pv","retention":os.environ["TRACE_RETENTION"]},"exporters":{}}
print(json.dumps({"spec":{"monitoring":m}}))
PYOBS
)
  # Compare the requested fields to live monitoring configuration. Ignore unrelated/defaulted fields.
  # A subsequent idempotent --apply should not recycle a healthy dashboard.
  if ! OBS_PATCH="$patch" oc get dsci "$DSCI_NAME" -o json | python3 -c '
import json, os, sys
actual=json.load(sys.stdin).get("spec",{}).get("monitoring",{})
wanted=json.loads(os.environ["OBS_PATCH"])["spec"]["monitoring"]
def matches(current, target):
    if isinstance(target, dict):
        return isinstance(current,dict) and all(k in current and matches(current[k],v) for k,v in target.items())
    return current==target
sys.exit(0 if matches(actual,wanted) else 1)
'; then
    obs_changed=true
  fi
  oc patch dsci "$DSCI_NAME" --type=merge -p "$patch"
  wait_for 'DSCI Ready after observability update' "$READY_TIMEOUT" 20 check_ready_condition dsci "$DSCI_NAME" ''
  wait_for 'RHOAI Prometheus available' "$READY_TIMEOUT" 20 obs_prom_ready
  if yes "$ENABLE_RHOAI_ALERTING"; then wait_for 'RHOAI Alertmanager available' "$READY_TIMEOUT" 20 obs_alert_ready; fi
  if yes "$ENABLE_RHOAI_TRACING"; then
    wait_for 'RHOAI OpenTelemetry Collector available' "$READY_TIMEOUT" 20 obs_otel_ready
    wait_for 'RHOAI Tempo available' "$READY_TIMEOUT" 20 obs_tempo_ready
  fi
  wait_for 'RHOAI Perses dashboard available' "$READY_TIMEOUT" 20 obs_perses_ready
  wait_for 'RHOAI Dashboard ObservabilityAvailable=True' "$READY_TIMEOUT" 20 obs_dashboard_integration_ready
  # A rollout is helpful when observability was added after the dashboard started.
  # It is deliberately conditional, not performed on every idempotent rerun.
  if yes "${OBS_RESTART_DASHBOARD_ON_CHANGE:-true}" && [[ "$obs_changed" == true ]]; then
    log 'Observability changed; restarting only rhods-dashboard after Perses and integration readiness'
    oc rollout restart deployment/rhods-dashboard -n redhat-ods-applications
    oc rollout status deployment/rhods-dashboard -n redhat-ods-applications --timeout="${OBS_DASHBOARD_ROLLOUT_TIMEOUT:-300}s"
    wait_for 'RHOAI Dashboard ObservabilityAvailable after restart' "$READY_TIMEOUT" 20 obs_dashboard_integration_ready
  else
    log 'Observability unchanged or dashboard restart disabled; preserving existing dashboard pods'
  fi
  log 'RHOAI observability components and dashboard integration are Ready (browser/API response requires real-cluster validation).'
}
obs_perses_ready() {
  oc get pods -n "$OBS_NAMESPACE" -o json | python3 -c 'import json,sys; a=[p for p in json.load(sys.stdin).get("items",[]) if p["metadata"]["name"].startswith("data-science-perses-")]; sys.exit(0 if a and all(any(c.get("type")=="Ready" and c.get("status")=="True" for c in p.get("status",{}).get("conditions",[])) for p in a) else 1)'
}
obs_dashboard_integration_ready() {
  oc get dashboard.components.platform.opendatahub.io default-dashboard -o json | python3 -c 'import json,sys; s=json.load(sys.stdin).get("status",{}); c=s.get("conditions",[]); sys.exit(0 if any(x.get("type")=="ObservabilityAvailable" and x.get("status")=="True" for x in c) else 1)'
}
obs_prom_ready() { oc get pods -n "$OBS_NAMESPACE" -o json | python3 -c 'import json,sys; a=[p for p in json.load(sys.stdin).get("items",[]) if p["metadata"]["name"].startswith("prometheus-data-science-monitoringstack-")]; sys.exit(0 if a and all(any(c.get("type")=="Ready" and c.get("status")=="True" for c in p.get("status",{}).get("conditions",[])) for p in a) else 1)'; }
obs_alert_ready() { oc get pods -n "$OBS_NAMESPACE" -o json | python3 -c 'import json,sys; a=[p for p in json.load(sys.stdin).get("items",[]) if p["metadata"]["name"].startswith("alertmanager-data-science-monitoringstack-")]; sys.exit(0 if a and all(any(c.get("type")=="Ready" and c.get("status")=="True" for c in p.get("status",{}).get("conditions",[])) for p in a) else 1)'; }
obs_otel_ready() { oc get pods -n "$OBS_NAMESPACE" -o json | python3 -c 'import json,sys; a=[p for p in json.load(sys.stdin).get("items",[]) if p["metadata"]["name"].startswith("data-science-collector-collector-")]; sys.exit(0 if a and all(any(c.get("type")=="Ready" and c.get("status")=="True" for c in p.get("status",{}).get("conditions",[])) for p in a) else 1)'; }
obs_tempo_ready() { oc get pods -n "$OBS_NAMESPACE" -o json | python3 -c 'import json,sys; a=[p for p in json.load(sys.stdin).get("items",[]) if p["metadata"]["name"].startswith("tempo-data-science-tempomonolithic-")]; sys.exit(0 if a and all(any(c.get("type")=="Ready" and c.get("status")=="True" for c in p.get("status",{}).get("conditions",[])) for p in a) else 1)'; }

rhoai_base() {
  ensure_olm rhods-operator redhat-ods-operator "$RHOAI_CHANNEL" redhat-operators all "$RHOAI_STARTING_CSV" "$RHOAI_EXPECTED_CSV_REGEX"
  wait_crd datascienceclusters.datasciencecluster.opendatahub.io
  wait_crd dscinitializations.dscinitialization.opendatahub.io
  if ! oc get dsci "$DSCI_NAME" >/dev/null 2>&1; then
    cat <<YAML | oc apply -f -
apiVersion: dscinitialization.opendatahub.io/v2
kind: DSCInitialization
metadata:
  name: $DSCI_NAME
spec:
  applicationsNamespace: redhat-ods-applications
  monitoring:
    managementState: Managed
    namespace: redhat-ods-monitoring
  trustedCABundle:
    managementState: Managed
YAML
  fi
  # Configurable baseline; MaaS later patches aigateway only.
  local a=Removed r=Removed f=Removed k=Removed t=Removed m=Removed w=Removed ml=Removed reg=Removed
  yes "$ENABLE_AIPIPELINES" && a=Managed
  yes "$ENABLE_RAY" && r=Managed
  yes "$ENABLE_FEAST" && f=Managed
  yes "$ENABLE_KSERVE" && k=Managed
  yes "$ENABLE_TRUSTYAI" && t=Managed
  yes "$ENABLE_MODELREGISTRY" && reg=Managed
  yes "$ENABLE_WORKBENCHES" && w=Managed
  yes "$ENABLE_MLFLOW_OPERATOR" && ml=Managed
  if ! oc get dsc "$DSC_NAME" >/dev/null 2>&1; then
    cat <<YAML | oc apply -f -
apiVersion: datasciencecluster.opendatahub.io/v2
kind: DataScienceCluster
metadata:
  name: $DSC_NAME
spec:
  components:
    aipipelines: {managementState: $a}
    dashboard: {managementState: Managed}
    feastoperator: {managementState: $f}
    kserve:
      managementState: $k
      rawDeploymentServiceConfig: Headed
    kueue: {managementState: Removed}
    mlflowoperator: {managementState: $ml}
    modelregistry:
      managementState: $reg
      registriesNamespace: rhoai-model-registries
    ray: {managementState: $r}
    trainer: {managementState: Removed}
    trainingoperator: {managementState: Removed}
    trustyai: {managementState: $t}
    workbenches:
      managementState: $w
      workbenchNamespace: rhods-notebooks
    ogx: {managementState: Removed}
YAML
  else
    log "Existing $DSC_NAME found; preserving components and enabling MLflow if requested"
    if yes "$ENABLE_MLFLOW_OPERATOR"; then
      oc patch dsc "$DSC_NAME" --type=merge -p '{"spec":{"components":{"mlflowoperator":{"managementState":"Managed"}}}}'
    fi
  fi
  wait_for "DSCI $DSCI_NAME Ready" "$READY_TIMEOUT" 20 check_ready_condition dsci "$DSCI_NAME" ''
  wait_for "DSC $DSC_NAME Ready" "$READY_TIMEOUT" 20 check_ready_condition dsc "$DSC_NAME" ''
}
mlflow_instance() {
  yes "$MLFLOW_DEPLOY_INSTANCE" || { log 'MLflow operator only; instance deferred by configuration'; return; }
  yes "$ENABLE_MLFLOW_OPERATOR" || die 'MLFLOW_DEPLOY_INSTANCE requires ENABLE_MLFLOW_OPERATOR'
  yes "$NOOBAA_ENABLED" && yes "$CNPG_ENABLED" || die 'MLflow instance needs NooBaa and CloudNativePG'
  wait_crd mlflows.mlflow.opendatahub.io
  wait_crd objectbucketclaims.objectbucket.io
  ensure_ns "$MLFLOW_DB_NAMESPACE"; ensure_ns "$MLFLOW_NAMESPACE"
  if ! oc get cluster.postgresql.cnpg.io "$MLFLOW_DB_CLUSTER" -n "$MLFLOW_DB_NAMESPACE" >/dev/null 2>&1; then
    cat <<YAML | oc apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: $MLFLOW_DB_CLUSTER
  namespace: $MLFLOW_DB_NAMESPACE
spec:
  instances: $MLFLOW_DB_INSTANCES
  bootstrap:
    initdb:
      database: mlflow
      owner: mlflow
  storage:
    size: $MLFLOW_DB_STORAGE_SIZE
    storageClass: $MLFLOW_DB_STORAGE_CLASS
YAML
  fi
  wait_for 'MLflow CNPG Ready' "$READY_TIMEOUT" 20 check_ready_condition clusters.postgresql.cnpg.io "$MLFLOW_DB_CLUSTER" "$MLFLOW_DB_NAMESPACE"
  wait_for 'MLflow CNPG application credentials' 600 10 oc get secret "$MLFLOW_DB_CLUSTER-app" -n "$MLFLOW_DB_NAMESPACE"
  # Build safe URI without stdout; oc create secret from literal is not logged.
  MLFLOW_DB_NS="$MLFLOW_DB_NAMESPACE" MLFLOW_DB_NAME="$MLFLOW_DB_CLUSTER" MLFLOW_TARGET_NS="$MLFLOW_NAMESPACE" python3 - <<'PY'
import base64,json,os,subprocess,urllib.parse
ns=os.environ['MLFLOW_DB_NS']; name=os.environ['MLFLOW_DB_NAME']; target=os.environ['MLFLOW_TARGET_NS']
s=json.loads(subprocess.check_output(['oc','get','secret',name+'-app','-n',ns,'-o','json']))['data']
dec=lambda k:base64.b64decode(s[k]).decode() if k in s else ''
# CNPG-generated secret may contain a short service hostname valid only in its
# own namespace. Always construct the full service DNS for other namespaces.
uri='postgresql://'+urllib.parse.quote(dec('username'),safe='')+':'+urllib.parse.quote(dec('password'),safe='')+'@'+name+'-rw.'+ns+'.svc.cluster.local:5432/mlflow'
uri+=('&' if '?' in uri else '?')+'sslmode=require' if 'sslmode=' not in uri else ''
secret={'apiVersion':'v1','kind':'Secret','metadata':{'name':'mlflow-db-credentials','namespace':target},'type':'Opaque','stringData':{'backend-store-uri':uri}}
subprocess.run(['oc','apply','-f','-'],input=json.dumps(secret),text=True,check=True,stdout=subprocess.DEVNULL)
PY
  if yes "$MLFLOW_TRUST_CNPG_CA"; then
    wait_for 'CNPG MLflow CA' 600 10 oc get secret "$MLFLOW_DB_CLUSTER-ca" -n "$MLFLOW_DB_NAMESPACE"
    MLFLOW_DB_NS="$MLFLOW_DB_NAMESPACE" MLFLOW_DB_NAME="$MLFLOW_DB_CLUSTER" DSCI_NAME="$DSCI_NAME" python3 - <<'PY'
import json,os,base64,subprocess
ns=os.environ['MLFLOW_DB_NS'];name=os.environ['MLFLOW_DB_NAME'];dsci=os.environ['DSCI_NAME']
s=json.loads(subprocess.check_output(['oc','get','secret',name+'-ca','-n',ns,'-o','json']))
ca=base64.b64decode(s['data']['ca.crt']).decode().strip()
d=json.loads(subprocess.check_output(['oc','get','dsci',dsci,'-o','json']))
cur=d.get('spec',{}).get('trustedCABundle',{}).get('customCABundle','')
if ca not in cur:
 bundle=(cur.rstrip()+'\n'+ca+'\n').lstrip()
 patch={'spec':{'trustedCABundle':{'managementState':'Managed','customCABundle':bundle}}}
 subprocess.run(['oc','patch','dsci',dsci,'--type=merge','-p',json.dumps(patch)],check=True,stdout=subprocess.DEVNULL)
PY
    wait_for 'DSCI Ready after CNPG CA' "$READY_TIMEOUT" 20 check_ready_condition dsci "$DSCI_NAME" ''
    # The namespace may receive an injected trusted CA bundle asynchronously.
    wait_for 'MLflow trusted CA bundle propagation' 600 20 oc get configmap odh-trusted-ca-bundle -n "$MLFLOW_NAMESPACE"
  fi
  if ! oc get obc "$MLFLOW_OBC_NAME" -n "$MLFLOW_NAMESPACE" >/dev/null 2>&1; then
    cat <<YAML | oc apply -f -
apiVersion: objectbucket.io/v1alpha1
kind: ObjectBucketClaim
metadata:
  name: $MLFLOW_OBC_NAME
  namespace: $MLFLOW_NAMESPACE
spec:
  generateBucketName: $MLFLOW_OBC_NAME
  storageClassName: openshift-storage.noobaa.io
YAML
  fi
  wait_for 'MLflow OBC Bound' "$READY_TIMEOUT" 15 check_phase obc "$MLFLOW_OBC_NAME" "$MLFLOW_NAMESPACE" Bound
  wait_for 'MLflow OBC Secret' 600 10 oc get secret "$MLFLOW_OBC_NAME" -n "$MLFLOW_NAMESPACE"
  wait_for 'MLflow OBC ConfigMap' 600 10 oc get configmap "$MLFLOW_OBC_NAME" -n "$MLFLOW_NAMESPACE"
  MLFLOW_NS="$MLFLOW_NAMESPACE" OBC="$MLFLOW_OBC_NAME" REGION="$MLFLOW_S3_REGION" python3 - <<'PY'
import base64,json,os,subprocess
ns=os.environ['MLFLOW_NS'];name=os.environ['OBC']
secret=json.loads(subprocess.check_output(['oc','get','secret',name,'-n',ns,'-o','json']))['data']
config=json.loads(subprocess.check_output(['oc','get','configmap',name,'-n',ns,'-o','json']))['data']
port=config.get('BUCKET_PORT','443');endpoint=('http' if port=='80' else 'https')+'://'+config['BUCKET_HOST']+':'+port
values={k:base64.b64decode(secret[k]).decode() for k in ('AWS_ACCESS_KEY_ID','AWS_SECRET_ACCESS_KEY')}
values.update({'AWS_DEFAULT_REGION':os.environ['REGION'],'AWS_REGION':os.environ['REGION'],'MLFLOW_S3_ENDPOINT_URL':endpoint,'AWS_S3_ENDPOINT':endpoint,'AWS_S3_BUCKET':config['BUCKET_NAME'],'AWS_EC2_METADATA_DISABLED':'true'})
obj={'apiVersion':'v1','kind':'Secret','metadata':{'name':'mlflow-s3-credentials','namespace':ns},'type':'Opaque','stringData':values}
subprocess.run(['oc','apply','-f','-'],input=json.dumps(obj),text=True,check=True,stdout=subprocess.DEVNULL)
PY
  local bucket
  bucket="$(oc get configmap "$MLFLOW_OBC_NAME" -n "$MLFLOW_NAMESPACE" -o jsonpath='{.data.BUCKET_NAME}')"
  # RHOAI 3.5: MLflow is cluster-scoped, named exactly "mlflow".
  [[ "$MLFLOW_NAME" == mlflow ]] || die "RHOAI 3.5 requires MLFLOW_NAME=mlflow"
  if ! oc get mlflow "$MLFLOW_NAME" >/dev/null 2>&1; then
    cat <<YAML | oc apply -f -
apiVersion: mlflow.opendatahub.io/v1
kind: MLflow
metadata:
  name: $MLFLOW_NAME
spec:
  replicas: $MLFLOW_REPLICAS
  backendStoreUriFrom:
    name: mlflow-db-credentials
    key: backend-store-uri
  artifactsDestination: "s3://$bucket/$MLFLOW_ARTIFACT_PREFIX"
  serveArtifacts: true
  envFrom:
  - secretRef:
      name: mlflow-s3-credentials
YAML
  fi
  wait_for "MLflow $MLFLOW_NAME Ready" "$READY_TIMEOUT" 20 check_ready_condition mlflow "$MLFLOW_NAME" ''
}
preflight() {
  check_oc
  if yes "$ODF_ENABLED"; then
    resolve_odf_channel
    check_existing_odf_channels "$ODF_CHANNEL"
  fi
  inspect_identity_provider
  require_numeric MIN_READY_WORKERS "$MIN_READY_WORKERS"
  require_numeric GPU_MACHINESET_REPLICAS "$GPU_MACHINESET_REPLICAS"
  oc get machinesets -n openshift-machine-api >/dev/null || die 'Machine API unavailable'
  select_worker_ms "$WORKER_MACHINESET_SOURCE_NAME" >/dev/null
  oc get storageclass "$NOOBAA_STORAGE_CLASS" >/dev/null || die "StorageClass $NOOBAA_STORAGE_CLASS unavailable"
  if yes "$NOOBAA_ENABLED"; then
    if oc get noobaa noobaa -n openshift-storage >/dev/null 2>&1 && ! oc get storagecluster -n openshift-storage -o name | grep -q .; then
      die "Direct NooBaa CR exists with no StorageCluster. Use reset-odf-lab.sh --check and --apply --confirm-destroy-odf on a disposable lab, or supply a clean cluster."
    fi
  fi
  log "Workers Ready=$(worker_count), desired=$(worker_desired_count), target=$MIN_READY_WORKERS"
  log "CPU MachineSet source: $(select_worker_ms "$WORKER_MACHINESET_SOURCE_NAME")"
  log "GPU $GPU_MACHINESET_REPLICAS x $GPU_MACHINESET_INSTANCE_TYPE, profile selector $GPU_SELECTOR_KEY=$GPU_SELECTOR_VALUE"
  log "RHOAI $RHOAI_STARTING_CSV / $RHOAI_CHANNEL; ODF $ODF_CHANNEL; MLflow instance=$MLFLOW_DEPLOY_INSTANCE"
  log 'Preflight passed; only --apply makes changes.'
}
# Enable RHOAI 3.5 dashboard feature previews for demonstration clusters.
# Flags expose UI capabilities; dependencies are installed in their respective stages.
enable_dashboard_features() {
  yes "${ENABLE_DASHBOARD_FEATURE_PREVIEWS:-true}" || { log 'Dashboard feature preview flags disabled'; return 0; }
  wait_for 'OdhDashboardConfig' "$READY_TIMEOUT" 15 oc get odhdashboardconfig odh-dashboard-config -n redhat-ods-applications
  local patch
  patch=$(cat <<'JSON'
{"spec":{"dashboardConfig":{
  "connectionTest":true,
  "projectRBAC":true,"roleManagement":true,
  "mcpCatalog":true,"mcpRegistry":true,
  "agentsCatalog":true,"agentOps":true,"agentConfigManagement":true,
  "externalModels":true,"aiAssetCustomEndpoints":true,"toolCalling":true,
  "genAiStudio":true,"autorag":true,"guardrails":true,
  "genAiTracing":true,"promptManagement":true,"globalProjectPrompts":true,
  "automl":true,"disableLMEval":false,
  "observabilityDashboard":true,"gpuaas":true,
  "modelAsService":true,"vLLMDeploymentOnMaaS":true,
  "llmdTemplates":true,"llmGatewayField":true
}}}
JSON
)
  log 'Enabling RHOAI 3.5 dashboard feature previews (Tech/Developer Preview)'
  oc patch odhdashboardconfig odh-dashboard-config -n redhat-ods-applications --type=merge -p "$patch"
  oc get odhdashboardconfig odh-dashboard-config -n redhat-ods-applications -o json | python3 -c '
import json,sys
c=json.load(sys.stdin)["spec"]["dashboardConfig"]
required=("connectionTest","mcpCatalog","mcpRegistry","agentsCatalog","agentOps","agentConfigManagement","externalModels","genAiStudio","autorag","guardrails","genAiTracing","promptManagement","globalProjectPrompts","automl","llmdTemplates","vLLMDeploymentOnMaaS","toolCalling")
missing=[k for k in required if c.get(k) is not True]
assert not missing, "Dashboard feature flags not persisted: " + ", ".join(missing)
print("Dashboard preview flags persisted; dependent services may require MaaS/OGX/observability configuration.")'
}

main() {
  preflight
  [[ "$MODE" == apply ]] || return 0
  configure_htpasswd
  scale_cpu_workers
  install_prereqs
  enable_odf_console
  provision_mcg
  make_gpu_machineset
  install_observability_operators
  rhoai_base
  configure_rhoai_observability
  mlflow_instance
  enable_dashboard_features
  log 'Baseline complete. Validate oc get dsc,dsci; then execute setup-maas.sh --check and --apply.'
  oc get nodes -L "$GPU_SELECTOR_KEY"
  oc get dsc,dsci
  oc get mlflow || :
}
main "$@"
