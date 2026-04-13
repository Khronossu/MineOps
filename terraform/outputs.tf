output "ecs_cluster_name" {
  description = "ECS cluster name"
  value       = module.ecs.cluster_name
}

output "ecs_service_name" {
  description = "ECS service name"
  value       = module.ecs.service_name
}

output "efs_id" {
  description = "EFS filesystem ID"
  value       = module.efs.efs_id
}

output "mod_bucket_name" {
  description = "S3 bucket for mod profiles"
  value       = module.storage.bucket_name
}

output "ecr_repository_url" {
  description = "ECR repository URL for the Minecraft image"
  value       = module.ecs.ecr_repository_url
}

output "control_api_url" {
  description = "HTTP API endpoint for the web control panel"
  value       = module.lambda.control_api_url
}
