output "vpc_id" {
  value = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "NetworkPolicy allow-list source for ALB -> pod traffic (target-type ip)."
  value       = aws_vpc.main.cidr_block
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Where EKS nodes and pods run."
  value       = aws_subnet.private[*].id
}

output "isolated_subnet_ids" {
  description = "No internet route. RDS lives here."
  value       = aws_subnet.isolated[*].id
}

output "nat_gateway_ids" {
  value = aws_nat_gateway.main[*].id
}

output "nat_public_ips" {
  description = "Source IPs pods present to third parties."
  value       = aws_eip.nat[*].public_ip
}
