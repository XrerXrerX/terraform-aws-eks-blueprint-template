variable "name_prefix" { type = string }

variable "kms_key_id" {
  type        = string
  description = "KMS key encrypting every SecureString."
}

variable "secret_names" {
  type        = list(string)
  description = "Parameter names (without the /<name_prefix>/ path) referenced by any workload."

  validation {
    condition     = alltrue([for n in var.secret_names : can(regex("^[A-Za-z0-9_.-]+$", n))])
    error_message = "Secret names may only contain letters, digits, '_', '.' and '-'."
  }
}
