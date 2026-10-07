output "buckets" {
  description = "Bucket key => { name, arn }."
  value = {
    for k, b in aws_s3_bucket.app : k => {
      name = b.bucket
      arn  = b.arn
    }
  }
}

output "alb_logs_bucket" {
  value = aws_s3_bucket.alb_logs.bucket
}
