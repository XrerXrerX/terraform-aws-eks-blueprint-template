variable "name_prefix" { type = string }

variable "rate_rules" {
  type = list(object({
    name       = string
    limit      = number
    path       = optional(string)
    constraint = optional(string, "STARTS_WITH")
  }))

  validation {
    condition     = alltrue([for r in var.rate_rules : r.limit >= 10])
    error_message = "AWS WAF rate limits must be >= 10."
  }

  validation {
    condition     = length(distinct([for r in var.rate_rules : r.name])) == length(var.rate_rules)
    error_message = "rate_rules names must be unique."
  }
}

variable "rate_window_seconds" {
  type = number

  validation {
    condition     = contains([60, 120, 300, 600], var.rate_window_seconds)
    error_message = "rate_window_seconds must be 60, 120, 300 or 600."
  }
}

variable "body_inspection_excluded_hosts" {
  type    = list(string)
  default = []
}

variable "log_retention_days" {
  type    = number
  default = 90
}
