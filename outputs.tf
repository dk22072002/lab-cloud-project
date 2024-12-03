output "load_balancer_dns" {
  value = aws_lb.spartanmarket_lb.dns_name
}

output "rds_endpoint" {
  value = aws_db_instance.spartanmarket_db.endpoint
}

output "bucket_name" {
  value = aws_s3_bucket.spartanmarket.id
}
