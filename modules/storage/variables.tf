variable "name_prefix" { type = string }

variable "kms_key_arn" {
  type        = string
  description = "SSE-KMS key for the application buckets."
}

variable "buckets" {
  type = map(object({
    versioning         = bool
    retention_days     = number
    glacier_after_days = number
  }))
}

variable "alb_log_retention_days" {
  type    = number
  default = 90
}
