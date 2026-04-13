output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "minecraft_sg_id" {
  value = aws_security_group.minecraft.id
}

output "efs_sg_id" {
  value = aws_security_group.efs.id
}

output "public_route_table_id" {
  value = aws_route_table.public.id
}
