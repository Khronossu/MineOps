resource "aws_efs_file_system" "minecraft" {
  encrypted        = true
  performance_mode = "generalPurpose"
  throughput_mode  = "bursting"

  lifecycle_policy {
    transition_to_ia = "AFTER_30_DAYS"
  }

  tags = {
    Name = "${var.project}-${var.environment}-efs"
  }
}

resource "aws_efs_backup_policy" "minecraft" {
  file_system_id = aws_efs_file_system.minecraft.id

  backup_policy {
    status = "ENABLED"
  }
}

resource "aws_efs_mount_target" "minecraft" {
  count           = length(var.private_subnet_ids)
  file_system_id  = aws_efs_file_system.minecraft.id
  subnet_id       = var.private_subnet_ids[count.index]
  security_groups = [var.efs_sg_id]
}

resource "aws_efs_access_point" "minecraft" {
  file_system_id = aws_efs_file_system.minecraft.id

  posix_user {
    uid = 1000
    gid = 1000
  }

  root_directory {
    path = "/minecraft"
    creation_info {
      owner_uid   = 1000
      owner_gid   = 1000
      permissions = "755"
    }
  }

  tags = {
    Name = "${var.project}-${var.environment}-efs-ap"
  }
}
