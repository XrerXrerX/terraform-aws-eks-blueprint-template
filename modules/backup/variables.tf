variable "name_prefix" { type = string }
variable "kms_key_arn" { type = string }

variable "retention_days" {
  type = number
}

variable "selection_tag" {
  type        = object({ key = string, value = string })
  description = "EC2 tag selecting the volumes to back up."
}

variable "schedule" {
  type        = string
  default     = "cron(0 3 * * ? *)"
  description = "Backup schedule (UTC)."
}
