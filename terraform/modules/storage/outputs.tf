output "bucket_name" {
  value = aws_s3_bucket.mods.bucket
}

output "bucket_arn" {
  value = aws_s3_bucket.mods.arn
}
