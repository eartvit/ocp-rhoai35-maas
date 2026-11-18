# OpenShift AI 3.5 on AWS OpenShift 4.22

This guide walks through setting up Red Hat OpenShift AI (RHOAI) with Models as a Service (MaaS) and an optional Model Context Protocol (MCP) Gateway demonstration.

The installation uses Bash scripts and the OpenShift CLI (`oc`). Some model and MCP configuration is completed in the RHOAI and Keycloak web consoles.

## 1. Before you start

You will need:

- An AWS-based OpenShift 4.22 cluster and an OpenShift account with cluster-admin access.
- A working OpenShift login. The scripts use your existing `oc` session.
- `bash`, `python3`, `oc`, and `base64` on the machine running the scripts.
- A configured OpenShift identity provider. The default configuration expects Keycloak/OpenID Connect.
- An appropriate storage class for persistent volumes. The supplied configuration uses `gp3-csi`.
- AWS capacity for the configured worker nodes and GPU instance type. The default GPU instance is `g6e.2xlarge` (one NVIDIA L40S).
- Access to the RHOAI and Keycloak web consoles for the manual steps.

Run the commands from the directory containing the scripts. Review the `.conf` files before applying any configuration. In particular, confirm the worker count, GPU instance type, storage classes, ingress certificate, operator channels, and Keycloak settings.

The scripts support two common modes:

- `--check` checks prerequisites without applying changes.
- `--apply` creates or updates the configured cluster resources.

> **Important:** `reset-odf-lab.sh` and `cleanup-noobaa.sh` are destructive maintenance tools. They are not part of the normal installation procedure.

### Files at a glance

| File | Purpose |
|---|---|
| `setup-cluster.sh` / `setup-cluster.conf` | OpenShift AI baseline: operators, ODF/MCG, GPU, observability, and MLflow |
| `rhoai-common.sh` | Shared functions used by the installation scripts |
| `setup-maas.sh` / `setup-maas.conf` | MaaS database, gateway, Kuadrant, Authorino, and GPU hardware profile |
| `setup-mcp.sh` / `setup-mcp.conf` | MCP Gateway operator and MCP infrastructure |
| `setup-mcp-demo.sh` / `setup-mcp-demo.conf` | OpenShift MCP demo service prerequisites, gateway registration, and access policies |
| `admin-get-token.sh`, `user-get-token.sh` | Obtain Keycloak access tokens for the demo |

## 2. Install the OpenShift AI baseline

First, authenticate to OpenShift and confirm that you are using the intended cluster:

```bash
oc whoami
oc get clusterversion
```

Open `setup-cluster.conf` and review the settings. The default configuration targets RHOAI 3.5, uses `ODF_CHANNEL=auto` to select the ODF channel matching the OpenShift minor release, and provisions a standalone Multi-Cloud Gateway (MCG) backed by persistent volumes.

Run:

```bash
bash setup-cluster.sh --check
bash setup-cluster.sh --apply
```

The installer provisions resources in this order:

1. Confirms cluster access and the required CPU workers.
2. Installs OpenShift Data Foundation (ODF), enables its console plugin, and provisions standalone MCG/NooBaa through an ODF `StorageCluster`.
3. Waits for the PV-backed storage resources and ObjectBucket storage class to become available.
4. Installs the remaining prerequisite operators.
5. Creates the GPU MachineSet and waits for an allocatable NVIDIA GPU.
6. Installs OpenShift AI and configures observability.
7. Creates the MLflow database, artifact bucket claim, and MLflow instance.
8. Enables the configured RHOAI dashboard features.

The default ObjectBucket storage class is `openshift-storage.noobaa.io`. The installer creates the MLflow artifact ObjectBucketClaim and requires it to reach `Bound`.

At completion, check the core resources:

```bash
oc get nodes -L gpu.openshift.ai/accelerator
oc get dsc,dsci
oc get mlflow
oc get storagecluster,noobaa,backingstore,bucketclass -n openshift-storage
oc get obc -A
```

**Storage note:** Some AWS clusters cannot supply the root cloud credentials requested by NooBaa. The installer reports this separately from the PV-backed MCG checks. If you intend to use AWS-backed storage, resolve any credential provisioning warnings before configuring that storage.

## 3. Install Models as a Service (MaaS)

Review `setup-maas.conf`, particularly the gateway settings, MaaS database storage class, and GPU hardware profile values. GPU node selection is inherited from `setup-cluster.conf`.

```bash
bash setup-maas.sh --check
bash setup-maas.sh --apply
```

This step configures:

- User workload monitoring and a CloudNativePG database for MaaS.
- The OpenShift Gateway API resources and MaaS gateway hostname.
- Kuadrant, Authorino, and authorization-service TLS.
- The RHOAI MaaS component and default tenant.
- A `nvidia-gpu` hardware profile for model serving.

The script prepares MaaS infrastructure but **does not deploy a model or create an API subscription**.

### Deploy a model

In the **OpenShift AI dashboard**:

1. Open **AI hub → Models** and select the model to deploy (for example, `gpt-oss-20b`).
2. Follow **Deploy model** and enter the model deployment details.
3. Under **Deployment method**, choose **LLM inference service with llm-d**.
4. Select **Single node** if deploying on the configured single-GPU node, and choose the `nvidia-gpu` hardware profile.
5. In **Advanced settings**, choose the relevant model publishing and token-authentication options, including **Publish as MaaS** when appropriate.
6. Review and deploy the model. Wait until its inference service is ready.
7. Open **MaaS governance** to configure the required subscription and API key, then test an inference request.

If the MaaS governance menu or publishing option does not appear immediately after the MaaS installation, refresh the RHOAI dashboard before investigating the cluster configuration.

## 4. Install the MCP Gateway

The MCP Gateway is optional and can be installed after the MaaS infrastructure is ready.

Review `setup-mcp.conf`, then run:

```bash
bash setup-mcp.sh --check
bash setup-mcp.sh --apply
```

The installer configures the MCP Gateway operator, Gateway API resources, and MCP Lifecycle components. The gateway exposes:

| Listener | Purpose |
|---|---|
| HTTPS `mcp:443` | Public MCP Gateway endpoint |
| HTTP `mcps:8080` | Additional MCP listener for internal routing configurations |

The public MCP endpoint is printed by the script and follows this pattern:

```text
https://mcp.apps.<cluster-domain>/mcp
```

The MCP Gateway operator is installed from its configured OperatorHub channel (the supplied configuration uses `preview`). The name of an internal listener does not, by itself, restrict network access; review gateway and network exposure for your environment.

## 5. Prepare the OpenShift MCP demo

The following steps deploy an OpenShift MCP server and connect it to the MCP Gateway with Keycloak-based access controls.

### Step 5.1 — Create the RHOAI project

In the **OpenShift AI dashboard**:

1. Open **Projects → Create project**.
2. Create a project named `ocp-mcp-demo`.
3. Confirm it appears in the RHOAI projects list.

Create the project through the RHOAI dashboard so it is registered as an AI project.

### Step 5.2 — Prepare the service account and permissions

Run:

```bash
bash setup-mcp-demo.sh --prepare
```

This prepares the `mcp-viewer` ServiceAccount, its read-only permissions for the demo namespaces, and the `openshift-mcp-server-config` ConfigMap. It also grants the namespace metadata access needed by the demo's namespace-listing tool.

The preparation stage does not deploy the MCP server. Do that in the RHOAI interface next.

### Step 5.3 — Deploy the MCP server

In **RHOAI → AI hub → MCP servers → Catalog**, select the Red Hat **OpenShift MCP server** and choose **Deploy MCP server**.

Use these values:

| Setting | Value |
|---|---|
| Deployment name | `test-ocp-mcp` |
| Project | `ocp-mcp-demo` |
| Image | Catalog default OpenShift MCP server image (v0.4) |
| Port | `8080` |
| MCP path | `/mcp` |
| ServiceAccount | `mcp-viewer` |
| ConfigMap | `openshift-mcp-server-config` |
| ConfigMap mount path | `/etc/mcp-config` |
| Configuration arguments | `--config /etc/mcp-config/config.toml` |

In the YAML editor, confirm that the runtime uses `serviceAccountName: mcp-viewer`. Deploy the server and confirm it reaches **Ready**.

### Step 5.4 — Register the direct MCP server

In **RHOAI → AI hub → MCP servers → Registry**, create an **Active** entry with display name **OpenShift MCP Demo** and this server definition:

```json
{
  "name": "org.redhat/openshift-mcp-demo",
  "version": "0.4.0",
  "description": "Read-only OpenShift MCP demo",
  "remotes": [
    {
      "type": "streamable-http",
      "url": "http://test-ocp-mcp.ocp-mcp-demo.svc.cluster.local:8080/mcp"
    }
  ]
}
```

This registers the backend directly. The gateway integration is configured in a later step.

## 6. Configure Keycloak for MCP access

Use the existing Keycloak instance and the `sso` realm. The demo uses ordinary realm users named `admin` and `user1`, distinct from any temporary Keycloak administration account.

In **Keycloak → Clients → Create client**, configure:

| Setting | Value |
|---|---|
| Client type | OpenID Connect |
| Client ID | `mcp-gateway` |
| Client authentication | Off (public client) |
| Standard flow | On |
| PKCE | `S256` |
| Implicit flow | Off |
| Direct access grants | On, for this lab's token helper scripts |

Under **Client scopes → mcp-gateway-dedicated**, add an **Audience** mapper:

| Setting | Value |
|---|---|
| Mapper name | `mcp-gateway-audience` |
| Included Client Audience | `mcp-gateway` |
| Add to access token | On |
| Add to ID token | Off |

The gateway expects access tokens issued by the realm, including the `mcp-gateway` audience. The demo's user-based policies distinguish `admin` and `user1`.

For lab use, configure an appropriate access-token lifespan under the client's advanced settings. The supplied demo uses password-based token retrieval; keep **Direct access grants disabled in production** and use an appropriate interactive or machine-to-machine flow there.

Do not place Keycloak passwords or access tokens in `.conf` files.

## 7. Configure MCP Gateway federation and policies

After the MCP server is deployed and registered in the RHOAI Registry, and the Keycloak client is ready, run:

```bash
bash setup-mcp-demo.sh --check
bash setup-mcp-demo.sh --apply
```

The script configures the backend route, MCP server registration, virtual servers, Keycloak JWT authentication, tool authorization policies, gateway routing, and Playground MCP discovery.

The two demo identities are configured with different tool selections:

| User | Available MCP tools |
|---|---|
| `admin` | 13 OpenShift MCP tools |
| `user1` | 3 tools: `ocp_pods_get`, `ocp_pods_list_in_namespace`, `ocp_pods_log` |

### Register the MCP Gateway in RHOAI

After the apply stage completes, return to **RHOAI → AI hub → MCP servers → Registry** and create a second **Active** entry:

- **Display name:** `OpenShift MCP Gateway`
- **Server definition:**

```json
{
  "name": "org.redhat/openshift-mcp-gateway",
  "version": "0.7.1",
  "description": "Keycloak-authenticated MCP Gateway with per-user tool selection",
  "remotes": [
    {
      "type": "streamable-http",
      "url": "https://mcp.apps.<cluster-domain>/mcp"
    }
  ]
}
```

Replace `<cluster-domain>` with your cluster's actual applications domain. Prefer the complete Gateway URL printed by `setup-mcp-demo.sh --apply`.

The Registry entries are created in the RHOAI UI. The script separately publishes the demo endpoints for Playground discovery.

## 8. Use the MCP demo in AI Playground

1. Open **RHOAI → Gen AI studio → Playground** and choose the deployed model.
2. Open the Playground's **Settings → MCP** section.
3. Select **OpenShift-MCP-Gateway**. Deselect the direct **OpenShift-MCP-Demo** endpoint so requests go through the gateway policies.
4. Choose **Authorize MCP server** and paste a Keycloak access token.
5. Try an OpenShift question that requires an MCP tool, and inspect the tool call and response in the Playground.

On a Fedora desktop with `wl-copy` available, the helper scripts can request a user token and place it on the clipboard:

```bash
./user-get-token.sh user1
# or
./admin-get-token.sh admin
```

The scripts prompt for the user's Keycloak password. Paste the resulting token into the authorization dialog **without** adding `Bearer `.

For `user1`, the Gateway should expose three pod-inspection tools. For `admin`, it should expose all 13 configured OpenShift MCP tools. Confirm that the Playground actually invokes the expected tool and returns cluster data.

The demo's backend ServiceAccount is read-only for its configured resources. Gateway authentication, virtual-server selection, and tool-level authorization are separate controls; review them before adapting this setup to a shared or production environment.

## 9. Useful checks and maintenance

Check the main OpenShift AI and MaaS resources:

```bash
oc get dsc,dsci
oc get gateway -A
oc get kuadrant -n kuadrant-system
oc get maastenantconfig -n models-as-a-service
oc get deployment maas-api -n redhat-ai-gateway-infra
```

Check storage and MLflow:

```bash
oc get storagecluster,noobaa,backingstore,bucketclass -n openshift-storage
oc get obc -A
oc get mlflow
```

Check the MCP resources:

```bash
oc get gateway -n mcp-system
oc get mcpserverregistration,mcpvirtualserver -A
```

If a feature is missing immediately after installation, refresh the relevant RHOAI dashboard page and confirm that the corresponding resource is ready before making configuration changes.

For an existing cluster, run the appropriate script's `--check` mode before any subsequent `--apply`. Avoid running the ODF cleanup utilities as part of routine maintenance.
