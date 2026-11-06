# RHOAI 3.5.x automation — AWS OpenShift 4.21/4.22

This package updates the **supplied** Bash installers for an OpenShift 4.22.18 / RHOAI 3.5.2 / RHCL 1.4.3 deployment and retains the experimental OCP 4.21 gate. No Helm, Argo CD or GitHub mutations. `--check` modes are read-only; `--apply` and `--prepare` mutate the cluster. All credentials stay outside configuration files.

**Support boundary:** OCP 4.22 was functionally validated manually in this lab; the revised scripts have passed local syntax checks but **have not been run end-to-end on a newly provisioned cluster**. The MCP operator comes from OperatorHub `preview` and some dashboard functions are tech preview. Do not treat the demo authorization as a production security certification: direct forbidden `tools/call` and spoofed-header tests were intentionally skipped.

## Files and responsibilities

- `setup-cluster.sh`, `.conf`, `rhoai-common.sh`: operator prerequisites; ODF standalone MCG/NooBaa; GPU; observability; RHOAI; MLflow.
- `setup-maas.sh`, `.conf`: MaaS database/Gateway/Authorino TLS and native provider readiness, hardware profile. No LLM is automatically deployed.
- `setup-mcp.sh`, `.conf`: **generic** MCP Gateway operator, two listeners and MCP Lifecycle; no demo backend or Keycloak policies.
- `setup-mcp-demo.sh`, `.conf`: **demo-specific** preparation followed by post-UI Gateway federation and policies.
- `admin-get-token.sh`, `user-get-token.sh`: clipboard token retrieval for controlled lab only.
- `reset-odf-lab.sh`, `cleanup-noobaa.sh`: destructive, explicitly confirmed lab tools preserved from source. They are NOT part of normal setup.

## 1. Baseline on a fresh OCP cluster

Authenticate as OpenShift cluster admin and review `setup-cluster.conf`, especially storage class (`gp3-csi` on this lab), AWS region, worker MachineSets, GPU instance type and all operator channels. `ODF_CHANNEL=auto` selects the exact OpenShift minor's ODF channel (4.21 or 4.22). RHOAI uses `stable-3.5`. `MLFLOW_S3_REGION=default` is used for NooBaa S3.

```bash
bash setup-cluster.sh --check
bash setup-cluster.sh --apply
```

**Updated ordering:** ODF operator installation is initiated first (using the correct catalog channel), followed by cert-manager and Service Mesh 3 **before RHCL**. The baseline does **not** prematurely create the Kuadrant custom resource: MaaS creates it after an accepted native GatewayClass exists and the Istio API CRDs are present. This avoids the observed `MissingDependency` reconciliation race. ODF StorageCluster/NooBaa is created or reused after installing operator prerequisites; wait for `NooBaa Ready`, `StorageCluster Ready`, PV-pool `BackingStore Ready`, `BucketClass Ready`, and the operator-generated `openshift-storage.noobaa.io` StorageClass before creating OBCs. No manual StorageClass creation.

**CCO warning:** On both Red Hat lab clusters `openshift-storage/noobaa-aws-cloud-creds` reported missing `kube-system/aws-creds`, while ODF PV-pool/NooBaa and OBCs were operational on the second cluster. NooBaa readiness does NOT prove AWS credential minting. Do not copy Machine API credentials into `aws-creds`. The installer reports the CCO failure but does **not abort solely on AWS credentials** when the standalone MCG operational gate verifies NooBaa, StorageCluster, the PV-pool default BackingStore, default BucketClass, and their operator-generated ObjectBucket StorageClass. It checks for existing Bound OBCs and later **requires MLflow’s actual artifact OBC to become Bound**. Failure of any operational requirement remains fatal after the configured timeout. AWS-backed stores are not treated as a safe exception; never fabricate root AWS credentials.

The baseline also fixes the observability `OBS_PATCH` pipeline/environment propagation defect and checks existing MLflow OBC readiness.

## 2. MaaS

```bash
bash setup-maas.sh --check
bash setup-maas.sh --apply
```

MaaS creates the native GatewayClass/Gateway and initializes Kuadrant only after detecting GatewayClass acceptance and required Istio CRDs; if a pre-existing Kuadrant CR is stuck on `MissingDependency`, it requests **one** metadata reconciliation before waiting for `Ready`. No repeated operator restarts. The installer uses the verified system CA path `/etc/pki/tls/certs/ca-bundle.crt` for Authorino; the old path `/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt` was absent. The working MaaS Gateway includes the model-controller TLS EnvoyFilter to Authorino.

**Manual RHOAI UI:** deploy `gpt-oss-20b` through llm-d with the `nvidia-gpu` hardware profile. Set up MaaS subscription/API key and verify inference through Playground. For the 13-tool MCP workflow, the lab needed 32,000 tokens/minute (1,000 resulted in 429). On a one-GPU cluster, stop the model temporarily if NVIDIA validator pods need to run after a restart.

## 3. Generic MCP infrastructure

```bash
bash setup-mcp.sh --check
bash setup-mcp.sh --apply
```

The Gateway uses `openshift-default`, the HTTPS listener `mcp:443` with wildcard `*.apps.<cluster-domain>`, and the additional HTTP listener `mcps:8080` with `mcp-internal.mcp.local`. Both are preserved. `MCPGatewayExtension` has `privateHost=https://mcp-gateway-openshift-default.mcp-system.svc.cluster.local:443` (configurable) and `publicHost=mcp.<apps-domain>`. Catalog selects the latest offered MCP Gateway Operator CSV in the `preview` channel. The 4.21 allowance is explicitly experimental and may not support federation.

`mcps:8080` is **not necessarily private** simply because its hostname says `internal`: assess Service/LoadBalancer and firewall exposure before sensitive use.

**MCP demo step order:** RHOAI UI creates `ocp-mcp-demo` → `--prepare` configures only prerequisites → RHOAI Catalog deploys `test-ocp-mcp` → RHOAI Registry UI registers the direct server → Keycloak UI configures `mcp-gateway` → `--check` / `--apply` configure federation and publish Playground entries → RHOAI Registry UI registers the Gateway → validate Playground.

## 4. Create RHOAI project in the UI, then prepare prerequisites

**Required sequence: create the AI project manually first.** In **RHOAI → Projects → Create project**, create `ocp-mcp-demo`. Do not create the namespace through `oc create namespace`; the RHOAI UI must recognize it as an AI project (`opendatahub.io/dashboard=true`).

Once the project appears in the RHOAI Projects list:

```bash
bash setup-mcp-demo.sh --prepare
```

This stage **requires the existing RHOAI project** and prepares only the `mcp-viewer` ServiceAccount, namespace-scoped `view` RoleBindings in `ocp-mcp-demo` and `llm-test`, and the ConfigMap `openshift-mcp-server-config` with `config.toml`. It also grants narrowly scoped cluster-wide `get/list` of **namespace metadata** for `ocp_namespaces_list`. This backend permission is shared by both Keycloak users; tool-level authorization needs independent validation for production. Secret access and write permissions are not granted.

**No MCP server is deployed, no Registry entry is created, and no Playground MCP endpoint is published by `--prepare`.** These are intentionally deferred so the UI cannot advertise an undeployed server. The RHOAI MCP Registry is configured manually in the UI; Playground discovery uses `redhat-ods-applications/gen-ai-aa-mcp-servers`, which `--apply` populates after successful federation.

### Manual UI: deploy the backend

In **RHOAI → AI hub → MCP servers → Catalog**, choose Red Hat `openshift-mcp-server` v0.4 and **Deploy MCP server**:

| Field | Value |
|---|---|
| Deployment name | `test-ocp-mcp` |
| Project | `ocp-mcp-demo` |
| OCI image | Catalog default (`openshift-mcp-server-rhel9:0.4`) |
| Port/path | `8080`, `/mcp` |
| Runtime security ServiceAccount | `mcp-viewer` |
| ConfigMap mount | `/etc/mcp-config` from `openshift-mcp-server-config` |
| Config arguments | `--config /etc/mcp-config/config.toml` |

`runtime.security.serviceAccountName: mcp-viewer` must appear in the YAML editor. Click Deploy. Wait for `MCPServer Ready=True, Accepted=True` and verify a Service/EndpointSlice for port 8080.

Then in **RHOAI UI → AI hub → MCP servers → Registry → Create MCP server**, create the *direct* backend entry with display name `OpenShift MCP Demo`, `Active` status, and:

```json
{"name":"org.redhat/openshift-mcp-demo","version":"0.4.0","description":"Read-only OpenShift MCP demo","remotes":[{"type":"streamable-http","url":"http://test-ocp-mcp.ocp-mcp-demo.svc.cluster.local:8080/mcp"}]}
```

The Registry entry is now present in the RHOAI UI, but the **Playground discovery entry is deliberately not published yet**. Do not expect to see or authorize `OpenShift-MCP-Demo` in Playground before `--apply`. The direct endpoint remains intended for validation, and should be unselected when testing the protected Gateway.

## 5. Manual Keycloak setup BEFORE demo post-install

Reuse the existing OpenShift `rhbk` Keycloak `sso` realm. Confirm ordinary users `admin` and `user1` exist; `temp-admin` is used only for the Keycloak admin console. Keycloak admin-console access is not required by these regular users.

In **Keycloak → Clients → Create client**:

- OpenID Connect client ID `mcp-gateway`; public client (Client authentication Off); Standard Flow On, PKCE `S256`, Implicit Off.
- For the **lab only**, enable **Direct access grants** to retrieve a token via curl; don't enable it in production. Redirect URIs can remain empty for this lab password-grant workflow; add exact callback URIs if later enabling interactive browser login.
- Under **Advanced → Access Token Lifespan**, set 1 day. In this lab the response was **36,000 seconds (10 hours)** due to other Keycloak limits; no realm-wide change is needed.
- Under **Client scopes → mcp-gateway-dedicated → Configure a new mapper → Audience**, set name `mcp-gateway-audience`, Included Client Audience `mcp-gateway`, Add to access token On, Add to ID token Off.
- A new token should have `iss=https://sso.apps.<cluster-domain>/realms/sso`, `aud=mcp-gateway`, `azp=mcp-gateway`, and `preferred_username` of `admin` or `user1`. Their Keycloak roles may differ; this lab uses **direct username matching**, not groups.

Do not store passwords or access tokens in these files.

## 6. Post-UI federation, JWT and Playground integration

After the RHOAI Catalog deployment, the manual **direct MCP Registry** entry, and Keycloak setup are complete, run:

```bash
bash setup-mcp-demo.sh --check
bash setup-mcp-demo.sh --apply
```

The second stage creates/reconciles these tested resources:

1. Backend HTTPRoute `mcp-system/test-ocp-mcp-backend`, parent `mcp` (public HTTPS listener), hostname `test-ocp-mcp.<apps-domain>`, cross-namespace ReferenceGrant to `ocp-mcp-demo/test-ocp-mcp:8080`.
2. A **RequestHeaderModifier removing `Authorization`** on backend forwarding. Without it, the backend MCP server can substitute the incoming Keycloak JWT for its Kubernetes ServiceAccount token, leading to `the server has asked for the client to provide credentials`.
3. `MCPServerRegistration/test-ocp-mcp`, prefix `ocp_`, `userSpecificList: Disabled`. Require Ready and `discoveredTools=13`; `servers` in the operator-managed `mcp-gateway-config` must contain the backend.
4. `admin-tools` MCPVirtualServer (all 13 federated tool names) and `user1-tools` (`ocp_pods_get`, `ocp_pods_list_in_namespace`, `ocp_pods_log`). Wait for both to appear in the controller-managed Secret. **Do not manually patch the Secret** when native reconciliation succeeds.
5. MCP-specific `mcp-gateway-authn-ssl` EnvoyFilter with `priority: -1`, Authorino gRPC destination 50051 and TLS trust via `/var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt` — adapted from the healthy MaaS filter. Authorino TLS stays enabled.
6. Gateway Keycloak JWT AuthPolicy, verified usernames and `x-mcp-virtualserver` selection. Separate backend HTTPRoute AuthPolicy for `x-mcp-toolname` and allowed calls. Both require Accepted and Enforced. Gateway policy alone does **not** establish tool authorization.
7. Passthrough OpenShift Route `mcp-gateway-playground` using the live apps domain and the Gateway-owned Service's HTTPS `mcp` port. This was necessary in the lab because `mcp.<apps-domain>` resolved to the standard OpenShift router, not the Gateway AWS LB. It is an ingress option, not strictly internal-only traffic; assess exposure for customers.
8. Publish **both** `OpenShift-MCP-Demo` (direct backend) and `OpenShift-MCP-Gateway` to `gen-ai-aa-mcp-servers` only at this final stage. Preserve any unrelated existing entries.

**RHOAI MCP Registry UI (after `--apply`):** create a second **Active** Registry entry, display name `OpenShift MCP Gateway`, with `server.json`:

```json
{"name":"org.redhat/openshift-mcp-gateway","version":"0.7.1","description":"Keycloak-authenticated MCP Gateway with per-user tool selection","remotes":[{"type":"streamable-http","url":"https://mcp.apps.<your-cluster-domain>/mcp"}]}
```

Replace the placeholder with the **live Gateway endpoint printed at the end of `setup-mcp-demo.sh --apply`**. On the validated cluster this was `https://mcp.apps.ocp.nbqpm.sandbox5271.opentlc.com/mcp`; a new cluster will have a different hostname. The script also prints a complete ready-to-paste Gateway `server.json`. Registry entries are created **manually through the RHOAI UI**, not by these scripts. Registry registration alone does not populate the Playground discovery ConfigMap.

### Validation and RHOAI Playground

1. Check the Route has `Admitted=True` and the public HTTPS URL without a token returns **401**. The Gateway backend authentication and tool authorization must be Enforced.
2. Run `./user-get-token.sh user1` or `./admin-get-token.sh admin` from Fedora with `wl-copy` installed. Each script prompts securely for the ordinary Keycloak user password, discovers the live issuer from OpenShift OAuth, obtains an access token, and copies **only** the token (without `Bearer `) to the clipboard. `KC_URL`, `KC_REALM`, `KC_CLIENT` may override discovery/defaults.
3. Open **RHOAI → AI Playground → Settings → MCP**, select `OpenShift-MCP-Gateway` and click **Authorize MCP server**. Paste the token. Unselect the direct `OpenShift-MCP-Demo` so it cannot bypass the Gateway. For `user1`, expect **3/3 tools**; ask GPT-OSS-20B to list pods in `llm-test` and expand the actual `ocp_pods_list_in_namespace` tool response.
4. Disconnect/reconnect with `admin` token: expect **13/13 tools**, successful `ocp_namespaces_list` and `ocp_projects_list`. The `mcp-viewer-namespace-reader` ClusterRole created during `--prepare` is necessary for the former.
5. Security caveat: manually constructing a forbidden `tools/call` request and spoofing client-supplied virtual-server/tool headers was **not performed** in the documented demonstration. Before customer use, validate this negative test and verify the backend policy matches the exact forwarding behavior of the operator. No `Enforced=True` condition alone is proof.

## Operational notes

- Never copy machine provisioning IAM credentials into `kube-system/aws-creds` as a guess. The lab CCO's `MissingRootCredential` warning persisted even though standalone MCG and OBCs were Ready; track independently.
- Do not change Gateway-managed HTTPRoute CRDs. OCP 4.21 lacked `HTTPRoute.spec.rules[].name`; OCP 4.22 has it, but manually adding the field did **not** fix registration. The successful federation change was public/private extension hosts plus wildcard matching and a backend route on `mcp:443`.
- `MCPServerRegistration Ready=True` and tool discovery must be checked independently. In this lab: 13 tools, 1 prompt.
- A model may fabricate an MCP error if it never executes a tool. Verify actual tool responses and backend logs.
- Do not rerun destructive ODF cleanup scripts against a healthy system. Their `--check` modes inspect the destructive scope first.
- Resource reconciliation uses `oc apply`, bounded waits, existing-resource checks and refuses critical conflicting resources wherever possible. The demo scripts are not intended to manage a customer-shared Gateway with different naming conventions.
