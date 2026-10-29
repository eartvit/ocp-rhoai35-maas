# Red Hat OpenShift AI 3.5 — AWS OpenShift 4.21 Demo Automation

> **Status: validated lab baseline with a limited MCP demonstration.** This repository provisions a Red Hat OpenShift AI (RHOAI) 3.5 environment on AWS OpenShift Container Platform (OCP) 4.21, then adds Models-as-a-Service (MaaS) and optionally MCP Gateway infrastructure. Some features are Technology Preview/Developer Preview; enabling MCP Lifecycle on OCP 4.21 is **experimental and outside its documented OCP 4.22+ support baseline**. Do not present this as a production-hardened deployment.

This repository is an **ordered set of Bash scripts**, not a Helm chart or Argo CD installation. It deliberately separates the core RHOAI platform, MaaS integration, and MCP-related components. The lab was validated with **RHOAI 3.5.2**, **RHCL 1.4.3**, **MCP Gateway Operator 0.7.1**, and one **AWS g6e.2xlarge (NVIDIA L40S)** GPU worker. Actual patch releases are selected by the cluster's OperatorHub catalog and existing installed subscriptions, subject to the individual scripts' compatibility checks.

## Quick start

```bash
# 1. Authenticate to the target OCP 4.21 cluster as a cluster administrator.
oc login --web
oc whoami

# 2. Review the configuration files before making any changes.
${EDITOR:-vi} setup-cluster.conf
${EDITOR:-vi} setup-maas.conf
${EDITOR:-vi} setup-mcp.conf

# 3. Install and verify the baseline.
./setup-cluster.sh --check
./setup-cluster.sh --apply

# 4. Install and verify MaaS.
./setup-maas.sh --check
./setup-maas.sh --apply

# 5. Optional: limited MCP Gateway and MCP Catalog infrastructure.
./setup-mcp.sh --check
./setup-mcp.sh --apply
```

**Important:** The final limited OCP 4.21 `setup-mcp.sh` and `setup-mcp.conf` come from the **`mcp-ocp421-limited`** package. Copy those two files into this script directory before committing. They replace earlier MCP scripts, including any experimental registration/rebuild variants. Keep `rhoai-common.sh` alongside the baseline and MaaS scripts.

`--check` is intended as read-only preflight; `--apply` makes cluster changes. Review every command and configuration before running on an existing environment. The order matters: **baseline → MaaS → optional MCP infrastructure → manual MCP demo**.

## Repository files

| File | Purpose |
| --- | --- |
| `setup-cluster.sh` | AWS worker/GPU provisioning, prerequisite operators, ODF standalone MCG/NooBaa, RHOAI 3.5, integrated observability, CNPG and MLflow |
| `setup-cluster.conf` | Baseline configuration: node sizing, labels/taints, operator channels, ODF, RHOAI components, MLflow and observability |
| `rhoai-common.sh` | Shared authentication, OpenShift/OLM checks, readiness helpers and operator installation functions; required by baseline and MaaS scripts |
| `setup-maas.sh` | MaaS-specific database, AI Gateway and Kuadrant configuration, tenant, dashboard integration and GPU hardware profile |
| `setup-maas.conf` | MaaS namespaces, gateway/TLS, database, tenant, model-related features and hardware-profile limits |
| `setup-mcp.sh` | **Limited OCP 4.21 MCP infrastructure**: installs/reuses MCP Gateway preview operator, creates unified Gateway/extension, optionally enables MCP Lifecycle. Does **not** register backend MCP servers or configure virtual servers |
| `setup-mcp.conf` | MCP namespace, Gateway hostname/TLS, operator channel and experimental MCP Lifecycle settings |
| `reset-odf-lab.sh` | **Destructive lab-only** teardown of standalone ODF/NooBaa and everything in `openshift-storage`; guarded by confirmation |
| `cleanup-noobaa.sh` | Legacy/special-purpose NooBaa cleanup helper; inspect independently before using; **not** part of the normal install or recommended reset sequence |

The repo may also contain historical reference scripts or packages. Use the files above as the OCP 4.21 flow; do not mix an old `setup-mcp.sh` or rebuild script into the final limited-demo branch.

## Prerequisites and assumptions

- Existing **OCP 4.21.x on AWS**, with `oc` logged in as a cluster administrator; existing RH Keycloak (`rhbk`) OpenID provider is reused. The scripts do **not** require or store the Keycloak admin password. An `oc login --web` session is appropriate for OIDC.
- Bash, `oc`, Python 3 and supporting command-line utilities used by the scripts (including `openssl` and base64 handling); inspect each script for specifics. Run them from a system with access to the cluster API and OperatorHub catalogs.
- Existing working AWS worker MachineSet, storage class (demo default `gp3-csi`), enough CPU-worker capacity, quota for the selected EC2 GPU instance, network connectivity and image-pull access.
- An AWS Cloud Credential Operator (CCO) **capable of fulfilling newly created CredentialsRequests**. `Available=True` on CCO alone does not prove that new AWS credentials can be minted.
- Existing/default OpenShift ingress controller with a **TLS certificate covering the derived `maas.<apps-domain>` and `mcp.<apps-domain>` names**, or appropriately configured host/certificate overrides.
- Adequate AWS cost/quotas for GPU, 1000-GiB demo GPU node root volume, persistent PostgreSQL volumes, object storage and observability.

> On another OCP minor release, use and validate the corresponding version-aware scripts/configurations. **This README documents the OCP 4.21 snapshot.** Earlier and later project iterations introduced OCP 4.22 support; do not assume a particular script copy supports 4.22 based solely on its filename.

## 1 — Configure and install the core cluster

Edit `setup-cluster.conf` first. In particular:

| Setting | Meaning / demo default |
| --- | --- |
| `IDENTITY_PROVIDER_MODE=keycloak` | Require an already-configured OpenShift OpenID identity provider; do not replace it with HTPasswd |
| `MIN_READY_WORKERS=3` | Minimum Ready CPU workers; preserves the control plane |
| `GPU_ENABLED=true` / `GPU_MACHINESET_REPLICAS=1` | Create/reuse one GPU worker |
| `GPU_MACHINESET_INSTANCE_TYPE=g6e.2xlarge` | AWS GPU instance with one L40S |
| `GPU_MACHINESET_ROOT_VOLUME_SIZE_GB=1000` | Demo GPU root disk size; review costs |
| `GPU_SELECTOR_KEY=gpu.openshift.ai/accelerator` / `GPU_SELECTOR_VALUE=nvidia` | GPU node selector reused by the MaaS hardware profile |
| `GPU_TAINT_KEY=nvidia.com/gpu` | GPU node taint used by model workloads |
| `ODF_ENABLED=true` / `NOOBAA_ENABLED=true` | Install **standalone MCG** managed by an ODF StorageCluster |
| `ODF_CHANNEL=stable-4.21` | ODF channel for this OCP 4.21 snapshot; adjust only with a version-aware installer for other OCP versions |
| `RHOAI_CHANNEL=stable-3.5` | RHOAI 3.5 release channel; OLM selects its offered patch release |
| `ENABLE_RHOAI_OBSERVABILITY=true` | Configure RHOAI metrics, alerting and tracing components |
| `ENABLE_DASHBOARD_FEATURE_PREVIEWS=true` | Expose preview UI controls; does not install every underlying service |
| `MLFLOW_DEPLOY_INSTANCE=true` | Provision MLflow service, CNPG database and S3 artifact bucket |

Run:

```bash
./setup-cluster.sh --check
./setup-cluster.sh --apply
```

The baseline script scales CPU workers **only when needed** using an eligible existing worker MachineSet; it does not resize or recreate control-plane MachineSets. It clones an AWS worker MachineSet for the GPU worker and applies the configured label/taint. The setup installs/reuses the required operators for NVIDIA/NFD, Leader Worker Set, JobSet, Pipelines, Service Mesh 3, cert-manager, RHCL, ODF, RHOAI, CNPG and the integrated observability dependencies according to configuration and cluster availability.

### ODF, NooBaa and MLflow

ODF is installed using the **StorageCluster-managed standalone Multicloud Object Gateway** path, matching the operator-backed console workflow. The script does **not** directly create a NooBaa CR or an ad-hoc bucket StorageClass. Wait for NooBaa readiness and the ObjectBucket StorageClass `openshift-storage.noobaa.io` before proceeding. The `odf-console` plugin is enabled while preserving other existing console plugins.

MLflow is provisioned with a CloudNativePG backend and an ObjectBucketClaim for S3 artifacts. Its installation therefore depends on a functioning MCG and OBC provisioner. Enabling an operator or a UI flag alone is not evidence of an operational MLflow instance.

Verify:

```bash
oc get dsci default-dsci
oc get dsc default-dsc
oc get noobaa -n openshift-storage
oc get storageclass openshift-storage.noobaa.io
oc get objectbucketclaims -A
oc get pods -n nvidia-gpu-operator
oc get pods -n redhat-ods-monitoring
```

**Known AWS failure:** On one RH-provisioned **OCP 4.22.18** lab, NooBaa remained in `Configuring` because CCO could not satisfy `openshift-storage/noobaa-aws-cloud-creds`: `kube-system/aws-creds` was absent. This persisted even after correcting ODF to `stable-4.22`. Do not increase timeouts or copy the Machine API credentials into `kube-system/aws-creds` blindly; establish the intended AWS credential-management mode. This was **not** the validated OCP 4.21 outcome.

### Observability and preview UI

The baseline config enables RHOAI's managed metrics, alerting and tracing and installs/reuses Cluster Observability, OpenTelemetry and Tempo operators. It waits on monitoring and dashboard conditions and may restart the dashboard **only when relevant observability configuration changes**. Preview dashboard flags expose features such as MCP Catalog, Agent-related pages, Gen AI Studio controls and other 3.5 features, but their backends must still be configured separately. This is a lab setup, not a claim that every preview feature is supported or operational.

## 2 — Configure MaaS and inference

Review `setup-maas.conf`. The script sources `setup-cluster.conf` for the GPU label, taint and instance type, so keep them consistent. MaaS uses a distinct Gateway from the MCP Gateway.

```bash
./setup-maas.sh --check
./setup-maas.sh --apply
```

The MaaS add-on configures its CNPG database, `models-as-a-service` tenant, infrastructure namespace, AI Gateway in `openshift-ingress`, certificate and hostname, the RHOAI MaaS features, and the GPU hardware profile (demo default `nvidia-gpu`). The MaaS Gateway accepts model HTTPRoutes from workload namespaces; this was required for llm-d `LLMInferenceService` routes in `llm-test`.

After installing MaaS, **deploy a model in the RHOAI UI**. The tested model was **GPT-OSS-20B**, served using llm-d/KServe on the single L40S. Configure a MaaS subscription and API key separately—**the setup script deliberately does not create a sample subscription or authorization policy**. When selecting the model in Playground, the MaaS-published entry `publishers/llm-test/models/gpt-oss-20b` was the working path in our lab, rather than the similarly named direct entry.

Useful checks:

```bash
oc get gateway maas-default-gateway -n openshift-ingress
oc get maastenantconfig -A
oc get llminferenceservices -A
oc get nodes -o custom-columns=NAME:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu
```

**GPU startup lesson:** On a single-GPU cluster, allow NVIDIA driver/toolkit/CUDA/**device-plugin** validation to complete before starting GPU-consuming inference. After a cluster restart, GPT-OSS-20B held the only GPU and the validator failed with `UnexpectedAdmissionError ... Requested: 1, Available: 0`. The validated recovery was to stop the model in the RHOAI UI, verify the node GPU allocation returned to zero, recreate failed NVIDIA validator pods, confirm validation, then restart the model. There was no need to reinstall the GPU Operator or reboot the node.

## 3 — Optional limited MCP infrastructure on OCP 4.21

Use the **final limited** `setup-mcp.sh` and `setup-mcp.conf`, not the earlier experimental registration/rebuild scripts:

```bash
./setup-mcp.sh --check
./setup-mcp.sh --apply
```

This installer checks existing RHCL/OperatorHub prerequisites, installs or reuses the Red Hat **`mcp-gateway` operator in its `preview` channel**, creates a unified `mcp-system/mcp-gateway` and `mcp-system/mcp-gateway` MCPGatewayExtension, sets public `mcp` HTTPS 443 and internal `mcps` HTTP 8080 listeners, and optionally enables MCP Lifecycle through `ENABLE_MCP_LIFECYCLE=true`.

The script dynamically discovers the OpenShift apps domain and default ingress TLS certificate and copies the certificate to `mcp-system`. If it detects a legacy MCP Gateway in `openshift-ingress`, it **refuses to silently replace it**; review any teardown separately. The HTTP 8080 listener must not be treated as private merely because it has an internal hostname. It is not production-authenticated by this installer.

**Critical scope:** On OCP 4.21 the MCP Gateway Operator and extension could become Ready, but **backend MCPServerRegistration did not become Ready or populate `mcp-gateway-config`**. `MCPVirtualServer`, tool-level Keycloak `AuthPolicy` and distinct 13-versus-3-tool visibility were **not validated**. Thus **the working OCP 4.21 demo uses a direct Playground → MCP backend connection, not Gateway federation**.

A reproduced controller/API discrepancy was `unknown field "spec.rules[0].name"` / `spec.rules[1].name`; `oc explain httproute.spec.rules.name` returned `field "name" does not exist` on OCP 4.21. This mismatch was observed, **not proven as the sole cause of the registration failure**. Do not replace OpenShift-managed Gateway API CRDs to work around it.

## 4 — Manual MCP server and Playground demonstration

The following are **demo-specific configuration steps**, not included in the reusable MCP infrastructure installer.

### MCP backend and Kubernetes permissions

Create the `ocp-mcp-demo` project and the read-only ServiceAccount:

```bash
oc new-project ocp-mcp-demo  # or use: oc project ocp-mcp-demo, if it exists
oc create serviceaccount mcp-viewer -n ocp-mcp-demo \
  --dry-run=client -o yaml | oc apply -f -

oc create rolebinding mcp-viewer-readonly -n ocp-mcp-demo \
  --clusterrole=view \
  --serviceaccount=ocp-mcp-demo:mcp-viewer \
  --dry-run=client -o yaml | oc apply -f -

# Optional: read-only access to model project as well.
oc create rolebinding mcp-viewer-readonly -n llm-test \
  --clusterrole=view \
  --serviceaccount=ocp-mcp-demo:mcp-viewer \
  --dry-run=client -o yaml | oc apply -f -
```

Create the MCP server config:

```bash
cat <<'TOML' > /tmp/openshift-mcp-config.toml
port = "8080"
read_only = true
cluster_provider_strategy = "in-cluster"
toolsets = ["core", "config"]

[[denied_resources]]
group = ""
version = "v1"
kind = "Secret"
TOML

oc create configmap openshift-mcp-server-config -n ocp-mcp-demo \
  --from-file=config.toml=/tmp/openshift-mcp-config.toml \
  --dry-run=client -o yaml | oc apply -f -
```

From **RHOAI → AI Hub → MCP Servers**, deploy the catalog OpenShift MCP server using the tested container `registry.redhat.io/openshift-mcp-tech-preview/openshift-mcp-server-rhel9:0.4`; in the deployment configuration use ServiceAccount `mcp-viewer`, mount `openshift-mcp-server-config` at `/etc/mcp-config` and pass `--config /etc/mcp-config/config.toml`. The test deployment produced Service `ocp-mcp-demo/test-ocp-mcp:8080` and endpoint:

```text
http://test-ocp-mcp.ocp-mcp-demo.svc.cluster.local:8080/mcp
```

Verify:

```bash
oc get mcpservers.mcp.x-k8s.io -n ocp-mcp-demo
oc get svc test-ocp-mcp -n ocp-mcp-demo
oc auth can-i list pods -n llm-test --as=system:serviceaccount:ocp-mcp-demo:mcp-viewer
```

The ServiceAccount remains namespace-scoped, even when the RHOAI user is an OpenShift administrator. The `view` role is not permission to read Secrets or modify workloads. For additional namespaces, create explicit RoleBindings; do **not** give the MCP ServiceAccount cluster-admin.

### MCP Registry registration in the RHOAI UI (manual)

**Do not skip this step.** The MCP Catalog deployment creates a running MCP server; the **MLflow-backed MCP Registry** creates its discoverable metadata and access-endpoint record. These are different from the Playground configuration below.

1. Open **RHOAI → AI Hub → MCP Servers → Registry → Create MCP server** (the precise navigation labels may differ slightly with dashboard updates).
2. Set **Display name** to `OpenShift MCP Demo`, **Status** to `Active`, and **Source** to `https://github.com/openshift/openshift-mcp-server`.
3. In the **server.json** editor, paste the following JSON **exactly** (change the URL only if you gave the backend Service a different name or namespace):

```json
{
  "name": "ocp-mcp-demo/openshift-mcp-server",
  "version": "0.4.0",
  "description": "Read-only OpenShift MCP server deployed in ocp-mcp-demo for testing Kubernetes resource inspection tools",
  "remotes": [
    {
      "type": "streamable-http",
      "url": "http://test-ocp-mcp.ocp-mcp-demo.svc.cluster.local:8080/mcp"
    }
  ]
}
```

4. Create/save the Registry entry and verify **OpenShift MCP Demo** appears with version `0.4.0` and `Active` status. The JSON `name` is the registry identifier, not the Kubernetes `MCPServer` name (`test-ocp-mcp`).
5. Open that Registry entry's **Connect** tab, select **Add endpoint**, and specify:

   | Field | Value |
   | --- | --- |
   | MCP Server | `ocp-mcp-demo/openshift-mcp-server` |
   | Endpoint URL | `http://test-ocp-mcp.ocp-mcp-demo.svc.cluster.local:8080/mcp` |
   | Version/Alias | `0.4.0` |
   | Transport Type | **Streamable HTTP** |

   Save and verify the access endpoint is listed. This **does not** create a Gateway registration or enforce authentication.
6. The Registry's **Tools** tab may initially say *No tools registered for this version*. Its **Auto-discover tools** action may show a Python/MLflow command, rather than execute it; in our test it displayed `mlflow.genai.refresh_mcp_server_version_tools(name="ocp-mcp-demo/openshift-mcp-server", version="0.4.0")`. Registry tool metadata was **not** required for our direct Playground connection to discover tools at runtime. Do not claim Registry tool auto-discovery succeeded unless you actually run and verify it.

### Playground MCP discovery and model test

**Important:** Creating an Active MCP Registry entry and adding its access endpoint **did not** make the server appear in the Playground on our OCP 4.21 test. The working discovery step was the separate ConfigMap `redhat-ods-applications/gen-ai-aa-mcp-servers`:

```bash
oc create configmap gen-ai-aa-mcp-servers -n redhat-ods-applications \
  --from-literal='OpenShift-MCP-Demo={"url":"http://test-ocp-mcp.ocp-mcp-demo.svc.cluster.local:8080/mcp","description":"Read-only OpenShift MCP server for inspecting Kubernetes resources in the demo project."}' \
  --dry-run=client -o yaml | oc apply -f -
```

Then:

1. In **Gen AI Studio → Playground**, select a project (we tested `ocp-mcp-demo` and another project) and choose the **MaaS-published** GPT-OSS-20B model, not an identically named direct endpoint. In our test the working published path contained `publishers/llm-test/models/gpt-oss-20b`.
2. Open **Settings → MCP**. Refresh the Playground page if necessary, select `OpenShift-MCP-Demo`, establish the connection, and check that **13 tools** are discovered.
3. Enable the tools and click **Save**. Tool discovery alone is not the same as authorizing or invoking tools.
4. Test read-only requests, for example:

   > Use the OpenShift MCP tools to list the pods in `ocp-mcp-demo`, including status and restarts.

   > Use the OpenShift MCP tools to list the pods in `llm-test`.

5. Confirm results come from tool calls, not just the model's general knowledge. The `llm-test` request needs the additional namespace-scoped RoleBinding created above; selecting a different Playground project does **not** grant the MCP ServiceAccount new Kubernetes RBAC permissions.

The direct MCP server uses its in-cluster HTTP URL. **This bypasses the RHCL MCP Gateway**, so neither Keycloak-based virtual-server filtering nor Gateway `AuthPolicy` governs these calls.

### MaaS subscription quota and common Playground issues

A MaaS subscription/API key must exist and have access to the published model before testing. Our original **1,000 tokens/minute** quota produced `429 Too Many Requests` errors after enabling all 13 MCP tools—even for a simple greeting. Changing the quota to **32,000 tokens/minute** resolved those errors in this demo. Tool schemas can consume substantial request context, but measured per-call token use was not available; do not treat 32K as a universal requirement.

If **No MCP servers available** is shown, verify the `gen-ai-aa-mcp-servers` ConfigMap and reload Playground. An Active MLflow Registry entry alone did not resolve that message. If tool calls can inspect `ocp-mcp-demo` but fail in `llm-test`, check the `mcp-viewer` RoleBinding in the target namespace, not the Playground user's OpenShift permissions. If model responses show HTTP 429, check the MaaS subscription's effective token rate limit before blaming the MCP endpoint.

### Security boundaries and limitations

- **Kubernetes RBAC:** `mcp-viewer` controls which cluster namespaces and resources the backend MCP server can inspect.
- **MCP tool permissions:** No Gateway-enforced user-specific tool filtering is established in this OCP 4.21 limited demo. Direct requests to the backend bypass Gateway authentication policies.
- **Keycloak users:** The planned `admin` (13 tools) versus `user1` (3 tools) virtual-server/authorization demo belongs to the separate OCP 4.22 full integration track.
- **Exposure:** Use network controls/NetworkPolicies appropriate to the lab. A read-only ServiceAccount alone does not authenticate all callers of an internal HTTP MCP endpoint.

## ODF teardown / recovery (disposable labs only)

The `reset-odf-lab.sh` utility is **destructive**. It deletes the standalone ODF StorageCluster, NooBaa resources, the entire `openshift-storage` namespace including any subscriptions/PVCs there, and the NooBaa ObjectBucket StorageClass. It intentionally preserves other namespaces and cluster-scoped CRDs. It refuses to run when existing ObjectBucketClaims/ObjectBuckets are detected and is not suitable for a shared or production ODF deployment.

```bash
./reset-odf-lab.sh --check
./reset-odf-lab.sh --apply --confirm-destroy-odf
```

Wait for deletion to complete; StorageCluster and namespace finalizers can require several minutes. Some older revisions have no periodic progress messages while waiting. Do not forcibly remove finalizers merely because the command is quiet. This README does **not** recommend using `cleanup-noobaa.sh` as a routine substitute for the full reset.

Once cleaned up, rerun the baseline check and installer. Do not use an ODF reset to fix unsatisfied AWS CCO credentials requests.

## Support boundaries and next development track

| Capability | OCP 4.21 limited lab | Planned OCP 4.22 track |
| --- | --- | --- |
| RHOAI 3.5.2, GPU, ODF/NooBaa, MLflow | Validated | Revalidate |
| MaaS + llm-d GPT-OSS-20B | Validated | Revalidate |
| MCP Lifecycle catalog deployment | Worked experimentally; not supported baseline | Validate on documented baseline |
| Direct MCP server → Playground (13 tools) | Validated | Validate |
| Gateway/extension infrastructure | Created; readiness reported | Validate with compatible APIs |
| MCP Gateway federation/registration | **Not working / not validated** | Required |
| MCPVirtualServer + Keycloak tool filtering | **Not working / not validated** | Required (admin 13 / user1 3) |

The new OCP 4.22 implementation should use the same high-level separation of baseline, MaaS and MCP scripts, but with version-aware ODF/channel selection and explicit checks that AWS CCO can provision new component credentials. Avoid repeating the failed OCP 4.21 Gateway registration patches without new evidence.

## References

**Official Red Hat documentation**

- [Installing and uninstalling OpenShift AI Self-Managed 3.5](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html-single/installing_and_uninstalling_openshift_ai_self-managed/index)
- [Governing LLM access with Models-as-a-Service](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html-single/govern_llm_access_with_models-as-a-service/index)
- [Working with the MCP Catalog](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html-single/working_with_the_mcp_catalog/index)
- [Red Hat Connectivity Link 1.4 — Install the MCP Gateway](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.4/html-single/install_the_mcp_gateway/index)

**Community/experimental references (not Red Hat product documentation)**

- [MCP ecosystem experimentation — `openshift` branch](https://github.com/jaideepr97/mcp-ecosystem-experimentation/tree/openshift) — design reference for future Keycloak, virtual-server and per-tool authorization work; do **not** copy older upstream operator versions into this baseline.

---

**Scope statement:** This README documents the demonstrated **OCP 4.21 RHOAI 3.5 limited-MCP stack**, including the manual steps necessary for Playground to call a read-only OpenShift MCP server. Gateway federation and per-user tool governance remain explicitly out of scope until separately validated on OCP 4.22.
