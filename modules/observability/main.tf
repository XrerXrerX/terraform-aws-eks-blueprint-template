# ---------------------------------------------------------------------------
# Alerting: one KMS-encrypted SNS topic, CloudWatch alarms on top of
# Container Insights, RDS, ElastiCache, the RAG node and the ALBs.
#
# Every alarm that watches "is it running" treats MISSING data as breaching:
# a workload scaled to zero or a silent metric is exactly when it must fire.
# ---------------------------------------------------------------------------

resource "aws_sns_topic" "alerts" {
  name              = "${var.name_prefix}-alerts"
  kms_master_key_id = var.kms_key_arn
}

resource "aws_sns_topic_subscription" "email" {
  for_each  = toset(var.alert_emails)
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

data "aws_iam_policy_document" "alerts" {
  statement {
    sid       = "AllowCloudWatchAlarms"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:cloudwatch:${var.aws_region}:${var.account_id}:alarm:*"]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.alerts.json
}

locals {
  topic = [aws_sns_topic.alerts.arn]

  # Service => namespace, for every workload watched by Container Insights.
  watched_services = merge(
    { for k, svc in var.app_services : k => { service = svc, namespace = var.apps_namespace } },
    var.rag_enabled ? { rag = { service = "rag-api", namespace = var.rag_namespace } } : {},
  )
}

# ===========================================================================
# Workloads (Container Insights)
# ===========================================================================
resource "aws_cloudwatch_metric_alarm" "no_running_pods" {
  for_each = local.watched_services

  alarm_name          = "${var.name_prefix}-${each.key}-no-running-pods"
  alarm_description   = "${each.key}: fewer than 1 running pod for 5 minutes."
  namespace           = "ContainerInsights"
  metric_name         = "service_number_of_running_pods"
  dimensions          = { ClusterName = var.cluster_name, Namespace = each.value.namespace, Service = each.value.service }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 5
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "breaching"
  alarm_actions       = local.topic
  ok_actions          = local.topic
}

resource "aws_cloudwatch_metric_alarm" "restarts" {
  for_each = local.watched_services

  alarm_name          = "${var.name_prefix}-${each.key}-crash-looping"
  alarm_description   = "${each.key}: more than 3 container restarts in 10 minutes."
  namespace           = "ContainerInsights"
  metric_name         = "pod_number_of_container_restarts"
  dimensions          = { ClusterName = var.cluster_name, Namespace = each.value.namespace, Service = each.value.service }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 2
  comparison_operator = "GreaterThanThreshold"
  threshold           = 3
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.topic
}

resource "aws_cloudwatch_metric_alarm" "memory_high" {
  for_each = local.watched_services

  alarm_name          = "${var.name_prefix}-${each.key}-memory-high"
  alarm_description   = "${each.key}: memory > 90% of its limit for 15 minutes (OOMKill risk)."
  namespace           = "ContainerInsights"
  metric_name         = "pod_memory_utilization_over_pod_limit"
  dimensions          = { ClusterName = var.cluster_name, Namespace = each.value.namespace, Service = each.value.service }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  comparison_operator = "GreaterThanThreshold"
  threshold           = 90
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.topic
}

# ===========================================================================
# Cluster / nodes
# ===========================================================================
resource "aws_cloudwatch_metric_alarm" "failed_nodes" {
  alarm_name          = "${var.name_prefix}-eks-failed-nodes"
  alarm_description   = "One or more nodes are NotReady."
  namespace           = "ContainerInsights"
  metric_name         = "cluster_failed_node_count"
  dimensions          = { ClusterName = var.cluster_name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 5
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.topic
  ok_actions          = local.topic
}

resource "aws_cloudwatch_metric_alarm" "node_memory_high" {
  alarm_name          = "${var.name_prefix}-eks-node-memory-high"
  alarm_description   = "Node memory > 90% for 15 minutes — the general pool may be at max_size."
  namespace           = "ContainerInsights"
  metric_name         = "node_memory_utilization"
  dimensions          = { ClusterName = var.cluster_name }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  comparison_operator = "GreaterThanThreshold"
  threshold           = 90
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.topic
}

resource "aws_cloudwatch_metric_alarm" "node_disk_high" {
  alarm_name          = "${var.name_prefix}-eks-node-disk-high"
  alarm_description   = "Node filesystem > 85% — image layers / logs filling the root volume."
  namespace           = "ContainerInsights"
  metric_name         = "node_filesystem_utilization"
  dimensions          = { ClusterName = var.cluster_name }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 3
  comparison_operator = "GreaterThanThreshold"
  threshold           = 85
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.topic
}

# ===========================================================================
# Dedicated RAG node + volumes
# ===========================================================================
resource "aws_cloudwatch_metric_alarm" "rag_node_down" {
  count = var.rag_enabled ? 1 : 0

  alarm_name          = "${var.name_prefix}-rag-node-down"
  alarm_description   = "The dedicated RAG node has no in-service instance. The group is fixed at 1, so this is an incident, not a scale-in."
  namespace           = "AWS/AutoScaling"
  metric_name         = "GroupInServiceInstances"
  dimensions          = { AutoScalingGroupName = var.rag_node_asg_name }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 5
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "breaching"
  alarm_actions       = local.topic
  ok_actions          = local.topic
}

resource "aws_cloudwatch_metric_alarm" "rag_volume" {
  for_each = var.rag_enabled ? {
    "data-warning"     = { volume = "data", threshold = 80, missing = "breaching" }
    "data-critical"    = { volume = "data", threshold = 90, missing = "notBreaching" }
    "vectors-warning"  = { volume = "vectors", threshold = 80, missing = "breaching" }
    "vectors-critical" = { volume = "vectors", threshold = 90, missing = "notBreaching" }
  } : {}

  alarm_name          = "${var.name_prefix}-rag-volume-${each.key}"
  alarm_description   = "RAG volume '${each.value.volume}' is over ${each.value.threshold}% full. Expand it (docs/OPERATIONS.md)."
  namespace           = var.rag_metrics_namespace
  metric_name         = "VolumeUtilization"
  dimensions          = { ClusterName = var.cluster_name, Volume = each.value.volume }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  comparison_operator = "GreaterThanThreshold"
  threshold           = each.value.threshold
  # The warning alarm owns "the sidecar stopped reporting".
  treat_missing_data = each.value.missing
  alarm_actions      = local.topic
  ok_actions         = local.topic
}

# ===========================================================================
# RDS
# ===========================================================================
resource "aws_cloudwatch_metric_alarm" "rds" {
  for_each = var.db_instance_id != null ? {
    cpu     = { metric = "CPUUtilization", op = "GreaterThanThreshold", threshold = 85, desc = "CPU > 85% for 15 minutes." }
    storage = { metric = "FreeStorageSpace", op = "LessThanThreshold", threshold = 5368709120, desc = "Free storage < 5 GiB." }
    memory  = { metric = "FreeableMemory", op = "LessThanThreshold", threshold = 268435456, desc = "Freeable memory < 256 MiB." }
  } : {}

  alarm_name          = "${var.name_prefix}-rds-${each.key}"
  alarm_description   = "RDS: ${each.value.desc}"
  namespace           = "AWS/RDS"
  metric_name         = each.value.metric
  dimensions          = { DBInstanceIdentifier = var.db_instance_id }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  comparison_operator = each.value.op
  threshold           = each.value.threshold
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.topic
  ok_actions          = local.topic
}

# ===========================================================================
# ElastiCache
# ===========================================================================
resource "aws_cloudwatch_metric_alarm" "redis_memory" {
  for_each = toset(var.redis_cluster_ids)

  alarm_name          = "${var.name_prefix}-redis-${each.key}-memory"
  alarm_description   = "Redis ${each.key}: memory > 85% — evictions imminent."
  namespace           = "AWS/ElastiCache"
  metric_name         = "DatabaseMemoryUsagePercentage"
  dimensions          = { CacheClusterId = each.key }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 3
  comparison_operator = "GreaterThanThreshold"
  threshold           = 85
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.topic
}

resource "aws_cloudwatch_metric_alarm" "redis_cpu" {
  for_each = toset(var.redis_cluster_ids)

  alarm_name          = "${var.name_prefix}-redis-${each.key}-cpu"
  alarm_description   = "Redis ${each.key}: engine CPU > 80% (Redis is single-threaded)."
  namespace           = "AWS/ElastiCache"
  metric_name         = "EngineCPUUtilization"
  dimensions          = { CacheClusterId = each.key }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  comparison_operator = "GreaterThanThreshold"
  threshold           = 80
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.topic
}

# ===========================================================================
# ALBs — created by the Load Balancer Controller, so discovered by tag.
# Gated: the data sources cannot resolve before the ALBs exist.
# ===========================================================================
data "aws_lbs" "group" {
  for_each = var.enable_alb_alarms ? toset(var.ingress_group_names) : toset([])
  tags = {
    "elbv2.k8s.aws/cluster" = var.cluster_name
    "ingress.k8s.aws/stack" = each.key
  }
}

data "aws_lb" "group" {
  for_each = data.aws_lbs.group
  arn      = one(each.value.arns)
}

resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  for_each = data.aws_lb.group

  alarm_name          = "${var.name_prefix}-alb-${each.key}-5xx"
  alarm_description   = "ALB ${each.key} is returning 5xx responses."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_ELB_5XX_Count"
  dimensions          = { LoadBalancer = each.value.arn_suffix }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 2
  comparison_operator = "GreaterThanThreshold"
  threshold           = 10
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.topic
}

resource "aws_cloudwatch_metric_alarm" "alb_target_5xx" {
  for_each = data.aws_lb.group

  alarm_name          = "${var.name_prefix}-alb-${each.key}-target-5xx"
  alarm_description   = "Pods behind ALB ${each.key} are returning 5xx responses."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  dimensions          = { LoadBalancer = each.value.arn_suffix }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 2
  comparison_operator = "GreaterThanThreshold"
  threshold           = 25
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.topic
}

resource "aws_cloudwatch_metric_alarm" "alb_latency" {
  for_each = data.aws_lb.group

  alarm_name          = "${var.name_prefix}-alb-${each.key}-latency"
  alarm_description   = "ALB ${each.key}: p95 target response time > 3s for 15 minutes."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  dimensions          = { LoadBalancer = each.value.arn_suffix }
  extended_statistic  = "p95"
  period              = 300
  evaluation_periods  = 3
  comparison_operator = "GreaterThanThreshold"
  threshold           = 3
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.topic
}
