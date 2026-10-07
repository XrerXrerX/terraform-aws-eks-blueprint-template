# Operations runbook

## Rotate a secret

```bash
echo 'API_JWT_SECRET=<new value>' > rotate.env
scripts/put-secrets.sh <prefix> rotate.env && rm rotate.env
```

External Secrets refreshes within `secret_refresh_interval` (default 1h);
force it now:

```bash
kubectl annotate externalsecret api-secrets -n apps force-sync=$(date +%s) --overwrite
```

Reloader then rolls the Deployment. No Terraform run needed.

The RDS master password can be rotated by RDS itself
(`aws rds modify-db-instance --rotate-master-user-password` or a rotation
schedule on the Secrets Manager secret); ESO picks it up the same way.

## Least-privilege database users

Apps receive the master credentials by default. Before production data:

```sql
-- PostgreSQL
CREATE ROLE api_user LOGIN PASSWORD '<generated>';
GRANT CONNECT ON DATABASE app TO api_user;
GRANT USAGE ON SCHEMA public TO api_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO api_user;
```

Store the credentials as SSM secrets (e.g. `API_DB_USERNAME`,
`API_DB_PASSWORD`), map them in the app's `secrets`, and set
`database = false` on the app (keep the `DB_HOST`/`DB_PORT` env in `env`).

## Scale

* **An app**: change `autoscaling.min_replicas` / `max_replicas`, apply.
* **General node pool**: change `general_node_group.max_size`, apply. The
  `node-memory-high` alarm tells you when the pool is saturated.
* **RAG**: vertical only — change `rag.node_instance_type` (causes a node
  replacement = RAG downtime; do it in a maintenance window).

## Expand a RAG volume

`volumeClaimTemplates` are immutable, so resize the PVC directly (the
StorageClass allows expansion):

```bash
kubectl -n rag patch pvc vectors-rag-0 -p '{"spec":{"resources":{"requests":{"storage":"200Gi"}}}}'
kubectl -n rag get pvc vectors-rag-0 -w      # wait for the new capacity
```

Then set `rag.vector_volume_gb = 200` in tfvars so the code matches reality
(Terraform ignores template changes, so this is documentation, not an action).

## Restore a RAG volume

1. AWS Backup console → vault `<prefix>-rag` → pick a recovery point →
   restore to a new EBS volume **in the RAG node's AZ**.
2. `kubectl -n rag scale statefulset rag --replicas=0`
3. Create a PV pointing at the restored volume ID and bind it to the PVC
   (or swap the volume behind the existing PV).
4. `kubectl -n rag scale statefulset rag --replicas=1`

For an application-consistent copy, also use Qdrant's own snapshot API
(`POST /collections/<name>/snapshots`) on a schedule.

## Upgrade Kubernetes

1. Check the EKS release calendar and the add-on / chart compatibility
   (Cluster Autoscaler's minor must match the cluster's).
2. Bump `kubernetes_version` (control plane first), apply.
3. Bump `node_kubernetes_version` (or leave it null to follow), apply — the
   general pool rolls one node at a time (PDBs respected); the RAG node
   replacement causes RAG downtime.
4. Bump `chart_versions` in `modules/eks-platform` as needed.

## Investigate

```bash
kubectl get events -A --sort-by=.lastTimestamp | tail -30
kubectl -n apps describe pod <pod>
kubectl -n kube-system logs deploy/aws-load-balancer-controller
kubectl -n kube-system logs deploy/external-dns
kubectl -n external-secrets logs deploy/external-secrets
aws ssm start-session --target <instance-id>     # node shell, no SSH
```

WAF blocks: CloudWatch Logs group `aws-waf-logs-<prefix>`.
ALB access logs: the `alb_logs` bucket (`terraform output s3_buckets`).
