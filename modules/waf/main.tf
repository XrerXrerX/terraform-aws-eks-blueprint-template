# ---------------------------------------------------------------------------
# Regional WAFv2 web ACL, attached to BOTH ALBs (public + admin) through the
# Ingress annotation `alb.ingress.kubernetes.io/wafv2-acl-arn`.
#
# Rules, in evaluation order:
#   0   AWS IP reputation list           (known-bad sources)
#   1   AWS anonymous IP list            (Tor / hosting-provider abuse)
#   5   AWS Common Rule Set (OWASP-ish)  body rules skip excluded hosts
#   6   AWS Known Bad Inputs             (Log4Shell & co.)
#   7   AWS SQL injection rule set
#   10+ per-IP rate limits from var.rate_rules
#
# SizeRestrictions_BODY is COUNTED, not blocked: legitimate JSON APIs often
# exceed its 8 KB limit. Re-enable it if none of your apps take large bodies.
# ---------------------------------------------------------------------------

locals {
  managed_rules = [
    { name = "AWSManagedRulesAmazonIpReputationList", priority = 0, metric = "IpReputation", scoped = false },
    { name = "AWSManagedRulesAnonymousIpList", priority = 1, metric = "AnonymousIp", scoped = false },
    { name = "AWSManagedRulesCommonRuleSet", priority = 5, metric = "CommonRuleSet", scoped = true },
    { name = "AWSManagedRulesKnownBadInputsRuleSet", priority = 6, metric = "KnownBadInputs", scoped = true },
    { name = "AWSManagedRulesSQLiRuleSet", priority = 7, metric = "SQLi", scoped = true },
  ]

  has_exclusions = length(var.body_inspection_excluded_hosts) > 0
}

resource "aws_wafv2_web_acl" "main" {
  name  = "${var.name_prefix}-alb"
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  dynamic "rule" {
    for_each = local.managed_rules
    content {
      name     = rule.value.name
      priority = rule.value.priority

      override_action {
        none {}
      }

      statement {
        managed_rule_group_statement {
          name        = rule.value.name
          vendor_name = "AWS"

          dynamic "rule_action_override" {
            for_each = rule.value.name == "AWSManagedRulesCommonRuleSet" ? ["SizeRestrictions_BODY"] : []
            content {
              name = rule_action_override.value
              action_to_use {
                count {}
              }
            }
          }

          # Body-inspecting groups skip the excluded hosts (e.g. a webhook
          # receiver whose XML payloads false-positive).
          dynamic "scope_down_statement" {
            for_each = rule.value.scoped && local.has_exclusions ? [1] : []
            content {
              not_statement {
                statement {
                  dynamic "or_statement" {
                    for_each = length(var.body_inspection_excluded_hosts) > 1 ? [1] : []
                    content {
                      dynamic "statement" {
                        for_each = var.body_inspection_excluded_hosts
                        content {
                          byte_match_statement {
                            positional_constraint = "EXACTLY"
                            search_string         = lower(statement.value)
                            field_to_match {
                              single_header {
                                name = "host"
                              }
                            }
                            text_transformation {
                              priority = 0
                              type     = "LOWERCASE"
                            }
                          }
                        }
                      }
                    }
                  }

                  dynamic "byte_match_statement" {
                    for_each = length(var.body_inspection_excluded_hosts) == 1 ? var.body_inspection_excluded_hosts : []
                    content {
                      positional_constraint = "EXACTLY"
                      search_string         = lower(byte_match_statement.value)
                      field_to_match {
                        single_header {
                          name = "host"
                        }
                      }
                      text_transformation {
                        priority = 0
                        type     = "LOWERCASE"
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = rule.value.metric
        sampled_requests_enabled   = true
      }
    }
  }

  dynamic "rule" {
    for_each = { for i, r in var.rate_rules : r.name => merge(r, { priority = 10 + i }) }
    content {
      name     = "rate-${rule.key}"
      priority = rule.value.priority

      action {
        block {}
      }

      statement {
        rate_based_statement {
          limit                 = rule.value.limit
          aggregate_key_type    = "IP"
          evaluation_window_sec = var.rate_window_seconds

          dynamic "scope_down_statement" {
            for_each = rule.value.path != null ? [1] : []
            content {
              byte_match_statement {
                positional_constraint = rule.value.constraint
                search_string         = lower(rule.value.path)
                field_to_match {
                  uri_path {}
                }
                text_transformation {
                  priority = 0
                  type     = "LOWERCASE"
                }
              }
            }
          }
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "Rate${replace(title(replace(rule.key, "-", " ")), " ", "")}"
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name_prefix}-alb"
    sampled_requests_enabled   = true
  }

  tags = { Name = "${var.name_prefix}-alb-waf" }
}

# WAF logs: blocked requests only (allowed traffic is already in ALB logs).
# The log group name MUST start with aws-waf-logs-.
resource "aws_cloudwatch_log_group" "waf" {
  name              = "aws-waf-logs-${var.name_prefix}"
  retention_in_days = var.log_retention_days
}

resource "aws_wafv2_web_acl_logging_configuration" "main" {
  resource_arn            = aws_wafv2_web_acl.main.arn
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]

  logging_filter {
    default_behavior = "DROP"
    filter {
      behavior    = "KEEP"
      requirement = "MEETS_ANY"
      condition {
        action_condition {
          action = "BLOCK"
        }
      }
      condition {
        action_condition {
          action = "COUNT"
        }
      }
    }
  }
}
