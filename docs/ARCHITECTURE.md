# Architecture

## Module graph

Dependencies only flow downward; nothing points back up.

```
kms ──┬─> secrets
      ├─> network ──> eks-cluster ──> eks-platform ──┬─> apps
      │                    │                         └─> rag
      │                    └──> data-stores ──────────────^
storage / dns / registry / waf ───────────────────────────^
observability, backup, cicd hang off the above.
```

* **data-stores sits below eks-cluster** because the node security group is
  the *only* ingress source for RDS and Redis.
* **eks-cluster depends on the whole network module**, not just subnet IDs.
  Otherwise `-target=module.eks_cluster` would skip NAT and private routes,
  and nodes in private subnets would never join (`NodeCreationFailure`).
* **apps / rag depend on eks-platform**: Ingresses are inert without the
  Load Balancer Controller, and ExternalSecrets need the ESO CRDs.

## Two node pools, on purpose

| | `general` | `rag` |
|---|---|---|
| Runs | every stateless app + controllers | the RAG StatefulSet only |
| Size | `min..max`, Cluster Autoscaler | exactly 1, never autoscaled |
| CA discovery tags | yes | **no** — CA cannot even see it |
| IAM | CA may resize it | CA's policy only mutates ASGs tagged `owned` |
| Taint | none | `workload=rag:NoSchedule` |
| AZ | all private subnets | pinned to one subnet |
| Capacity | on-demand (configurable) | on-demand, never Spot |

**Why RAG is not "just another pod".** A vector index (Qdrant) and the RAG data
directory live on ReadWriteOnce EBS volumes: one writer, one node, one AZ. If
an autoscaler decides the node is under-utilized and drains it, the volume is
detached from under a live database — that is how indexes get corrupted. So
the guarantees are layered:

1. node group `min = max = 1` — the ASG cannot shrink;
2. no Cluster Autoscaler discovery tags and an IAM condition that only allows
   mutating `owned` ASGs;
3. `cluster-autoscaler.kubernetes.io/safe-to-evict: "false"` on the pod;
4. a taint so nothing else competes for the node's memory;
5. StorageClass `WaitForFirstConsumer` (volume is created in the node's AZ)
   and `Retain` (deleting the PVC never deletes data);
6. daily AWS Backup snapshots selected by a tag the StorageClass stamps.

The trade-off is explicit: replacing the RAG node (AMI update, instance
failure) means RAG downtime while the volumes re-attach. For a single-writer
store that is unavoidable; for HA, move to a replicated vector DB (Qdrant
distributed mode) or a managed service and turn the StatefulSet's replicas up.

Want a GPU instead? Set `rag.node_ami_type = "AL2023_x86_64_NVIDIA"` and a
`g5`/`g6` instance type, and install the NVIDIA device plugin.

## Traffic

* **Two ALBs**, both created by the Load Balancer Controller from Ingress
  *groups*: `<prefix>-public` (0.0.0.0/0) and `<prefix>-admin`
  (`admin_allowed_cidrs`). They are separate because `inbound-cidrs` applies
  to the whole ALB security group — mixing groups would either lock the public
  site to operator IPs or expose admin tools to the world.
* ALB-wide settings (idle timeout, access logs, header hardening) are set once
  in `locals.tf`. Every Ingress in a group must carry identical
  `load-balancer-attributes`, so never override them per app.
* `target-type: ip` sends traffic straight to pod IPs. The namespaces carry
  `elbv2.k8s.aws/pod-readiness-gate-inject=enabled`, so a rollout only
  continues once the new pod is healthy *in the ALB*.
* **external-dns** writes Route53 records from Ingress hosts (`upsert-only`,
  TXT ownership). Terraform owns the zone and the ACM certificate.
* `exposure = "internal"` apps have no Ingress at all and are reachable only
  through their ClusterIP Service — and only from the pods NetworkPolicy allows.

## Secrets flow

```
operator ──put-secrets.sh──> SSM /<prefix>/NAME (SecureString, KMS)
RDS ──manages──> Secrets Manager (master credentials, KMS)
                     │
     External Secrets Operator (IRSA: read-only, own path + listed secrets)
                     │
     Kubernetes Secret <app>-secrets / <app>-db  (etcd envelope-encrypted, KMS)
                     │
     Pod envFrom  ── Reloader restarts the Deployment when the Secret changes
```

Terraform declares the *mapping* (ENV_VAR → parameter name) and never reads a
value.

## Image ownership

Terraform sets each container image **once**, at create time. From then on CI
owns it: it pushes an immutable git-SHA tag and runs `kubectl set image`.
`lifecycle.ignore_changes` on the image (and on `replicas`, owned by the HPA)
keeps an unrelated `terraform apply` from rolling production back.
See [examples/deploy-workflow.yml](../examples/deploy-workflow.yml).
