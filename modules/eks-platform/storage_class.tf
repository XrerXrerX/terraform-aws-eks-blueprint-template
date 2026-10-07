# ---------------------------------------------------------------------------
# StorageClasses on the EBS CSI driver, encrypted with the platform KMS key.
#
#   gp3     — cluster default for any PVC that does not name a class.
#             (Since EKS 1.30 the legacy in-tree gp2 class is no longer
#             annotated as default on new clusters, so there is no ambiguity.)
#   gp3-rag — identical, but stamps every volume with the backup tag that
#             modules/backup selects on. Only the RAG PVCs use it, so only
#             they are snapshotted.
#
# WaitForFirstConsumer: an EBS volume is AZ-bound, so it must not be created
#   until the scheduler has picked the pod's node. Immediate binding is how
#   you get a volume in one AZ and a pod stuck Pending in another.
# Retain: deleting a PVC (or the whole StatefulSet) never destroys data.
# ---------------------------------------------------------------------------

locals {
  rag_backup_tag = {
    key   = "backup-plan"
    value = "${var.name_prefix}-rag"
  }
}

resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  volume_binding_mode    = "WaitForFirstConsumer"
  reclaim_policy         = "Retain"
  allow_volume_expansion = true

  parameters = {
    type      = "gp3"
    encrypted = "true"
    kmsKeyId  = var.kms_key_arn
  }
}

resource "kubernetes_storage_class_v1" "gp3_rag" {
  metadata {
    name = "gp3-rag"
  }

  storage_provisioner    = "ebs.csi.aws.com"
  volume_binding_mode    = "WaitForFirstConsumer"
  reclaim_policy         = "Retain"
  allow_volume_expansion = true

  parameters = {
    type               = "gp3"
    encrypted          = "true"
    kmsKeyId           = var.kms_key_arn
    tagSpecification_1 = "${local.rag_backup_tag.key}=${local.rag_backup_tag.value}"
  }
}
