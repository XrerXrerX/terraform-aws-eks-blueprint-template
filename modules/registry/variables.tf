variable "name_prefix" { type = string }

variable "project" {
  type        = string
  description = "Repository namespace: <project>/<name>."
}

variable "repositories" {
  type        = list(string)
  description = "Repository names (one per image)."
}

variable "kms_key_arn" { type = string }

variable "keep_last_images" {
  type        = number
  default     = 30
  description = "Images kept per repository. Must cover your rollback window."
}
