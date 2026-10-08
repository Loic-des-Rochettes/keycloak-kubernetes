# Keycloak on Kubernetes with operators

A typical, platform-agnostic Keycloak deployment on Kubernetes, managed by
operators only:

- [CloudNativePG](https://cloudnative-pg.io/) 1.30.1: PostgreSQL cluster (1 primary, 2 standbys, quorum
  synchronous replication);
- [Keycloak Operator](https://www.keycloak.org/operator/installation) 26.8.0: 2 Keycloak pods, realm import;
- [Envoy Gateway](https://gateway.envoyproxy.io/) v1.9.2: Gateway API entry point, TLS termination, and
  protection of applications that know nothing about OpenID Connect.

It is the companion repository of the article
[Keycloak on Kubernetes with operators](https://blog.please-open.it/posts/keycloak-kubernetes-operators/).

> **No support, no warranty.** This is a reference to learn from and adapt, not a
> product. It was tested on the Kubernetes cluster of Docker Desktop (kind
> provisioning, single node). If you only need a Keycloak, a managed offer such
> as [Keycloak as a Service on Clever Cloud](https://www.clever.cloud/developers/doc/addons/keycloak/)
> is far simpler to run.

## What it deploys

```
                         https://*.kube.localhost
                                    |
                     Envoy Gateway (2 proxies, TLS)
          ___________________|___________________________
         |                   |                           |
 keycloak.kube.localhost  intranet.kube.localhost   api.kube.localhost
 keycloak-admin...           OIDC + JWT + UserInfo      JWT + roles
         |                   |        |                  |
   Keycloak x2          intranet   userinfo-authz     echo-api
         |              (legacy)   (ext_authz)
 PostgreSQL x3 (CloudNativePG)
```

| Namespace | Content |
|---|---|
| `cnpg-system` | CloudNativePG operator |
| `envoy-gateway-system` | Envoy Gateway controller, Envoy proxies, `public` Gateway |
| `keycloak` | Keycloak operator, Keycloak, PostgreSQL cluster |
| `demo` | `intranet`, `echo-api`, `userinfo-authz` (Python scripts mounted from a ConfigMap) |

| Path | Content |
|---|---|
| `00-namespaces.yaml` | Namespaces, Pod Security Admission, Gateway access label |
| `01-gateway/` | GatewayClass, EnvoyProxy, Gateway, HTTP to HTTPS redirect, header sanitizing |
| `02-database/` | CloudNativePG `Cluster` and its NetworkPolicy |
| `03-keycloak/` | `Keycloak` CR, PodDisruptionBudget, public and admin HTTPRoutes |
| `04-realm/` | `KeycloakRealmImport` of the `demo` realm |
| `05-demo/` | Demo applications, their HTTPRoutes, SecurityPolicies and NetworkPolicies |
| `scripts/` | Local CA, Secrets, shared test functions |

## Requirements

- A Kubernetes cluster where `LoadBalancer` Services are reachable, with a default
  StorageClass and a CNI that enforces NetworkPolicies. Docker Desktop with
  Kubernetes enabled (kind provisioning) provides all three.
- `kubectl` (with kustomize, built in), `git`, `curl`, `jq`, `openssl`.
- Around 6 GB of memory for the cluster.

## Deploy, test, remove

```bash
./deploy.sh              # 4 to 10 minutes, depending on image pulls
./test.sh                # end-to-end checks
./test-failover.sh       # PostgreSQL primary crash, Keycloak pods restart
./test-key-rotation.sh   # signing key rotation seen by Envoy (about 6 minutes)
./teardown.sh
```

`*.localhost` names resolve to `127.0.0.1` without any DNS setup in curl and in
Chromium-based browsers. To browse without certificate warnings, trust
`certs/ca.crt`, created by `deploy.sh`.

| URL | |
|---|---|
| https://intranet.kube.localhost | Legacy application, sign in as `alice` (allowed) or `bob` (403) |
| https://api.kube.localhost/items | API, bearer token required |
| https://keycloak.kube.localhost/realms/demo/account | Keycloak account console |
| https://keycloak-admin.kube.localhost/admin/ | Keycloak administration console |

Passwords and client secrets are random, stored in Secrets:

```bash
kubectl -n keycloak get secret demo-realm-secrets -o go-template='{{range $k, $v := .data}}{{$k}}: {{$v | base64decode}}{{"\n"}}{{end}}'
kubectl -n keycloak get secret keycloak-initial-admin -o go-template='{{.data.username | base64decode}} {{.data.password | base64decode}}{{"\n"}}'
```

## Multi-node and multi-site

Anti-affinity rules matter as soon as the cluster has several nodes or zones:
two Keycloak pods or two PostgreSQL instances on the same node do not survive the
loss of that node. This repository keeps the defaults (`preferred` rules and
`ScheduleAnyway` spread constraints), which also work on a single node. Comments
in `02-database/cluster.yaml` and `03-keycloak/keycloak.yaml` show the stricter
settings. They were not tested here.

## License

Distributed under the [Apache License 2.0](LICENSE), without any warranty.
