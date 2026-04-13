resource "aws_s3_bucket" "mods" {
  bucket = var.bucket_name

  tags = {
    Name = var.bucket_name
  }
}

resource "aws_s3_bucket_versioning" "mods" {
  bucket = aws_s3_bucket.mods.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "mods" {
  bucket = aws_s3_bucket.mods.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "mods" {
  bucket = aws_s3_bucket.mods.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "mods" {
  bucket = aws_s3_bucket.mods.id

  rule {
    id     = "expire-old-versions"
    status = "Enabled"

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

resource "aws_ssm_parameter" "active_profile" {
  name  = "/minecraft/active-profile"
  type  = "String"
  value = "vanilla"

  lifecycle {
    ignore_changes = [value]
  }

  tags = {
    Name = "minecraft-active-profile"
  }
}

resource "aws_ssm_parameter" "rcon_password" {
  name  = "/minecraft/rcon-password"
  type  = "SecureString"
  value = "CHANGE_ME_ON_FIRST_DEPLOY"

  lifecycle {
    ignore_changes = [value]
  }

  tags = {
    Name = "minecraft-rcon-password"
  }
}
