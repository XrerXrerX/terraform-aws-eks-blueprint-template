variable "name_prefix" { type = string }
variable "root_domain" { type = string }

variable "create_zone" {
  type        = bool
  description = "true = create the zone (then delegate NS). false = look it up."
}

variable "cert_sans" {
  type        = list(string)
  description = "Subject alternative names. Excludes the apex, which is the certificate's domain_name."
}

variable "caa_issuers" {
  type        = list(string)
  default     = ["amazon.com"]
  description = "CAs allowed to issue for root_domain (CAA record). [] = do not manage CAA."
}
