output "parameter_names" {
  value = sort([for p in aws_ssm_parameter.secret : p.name])
}
