output "cluster_name" {
  value = aws_ecs_cluster.minecraft.name
}

output "service_name" {
  value = aws_ecs_service.minecraft.name
}

output "ecr_repository_url" {
  value = aws_ecr_repository.minecraft.repository_url
}
