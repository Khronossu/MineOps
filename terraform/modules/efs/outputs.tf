output "efs_id" {
  value = aws_efs_file_system.minecraft.id
}

output "access_point_id" {
  value = aws_efs_access_point.minecraft.id
}
