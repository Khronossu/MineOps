resource "aws_ecr_repository" "minecraft" {
  name                 = "${var.project}-${var.environment}"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name = "${var.project}-${var.environment}-ecr"
  }
}

resource "aws_ecr_lifecycle_policy" "minecraft" {
  repository = aws_ecr_repository.minecraft.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 5 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = { type = "expire" }
    }]
  })
}

resource "aws_cloudwatch_log_group" "minecraft" {
  name              = "/minecraft/server"
  retention_in_days = 7

  tags = {
    Name = "minecraft-server-logs"
  }
}

resource "aws_ecs_cluster" "minecraft" {
  name = "${var.project}-${var.environment}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = {
    Name = "${var.project}-${var.environment}-cluster"
  }
}

resource "aws_iam_role" "task_execution" {
  name = "${var.project}-${var.environment}-task-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "task_execution_managed" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "task_execution_ssm" {
  name = "ssm-rcon-password"
  role = aws_iam_role.task_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameter", "ssm:GetParameters"]
      Resource = "arn:aws:ssm:${var.region}:${var.account_id}:parameter/minecraft/rcon-password"
    }]
  })
}

resource "aws_iam_role" "task" {
  name = "${var.project}-${var.environment}-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "task_ssm" {
  name = "ssm-active-profile"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameter"]
      Resource = "arn:aws:ssm:${var.region}:${var.account_id}:parameter/minecraft/active-profile"
    }]
  })
}

resource "aws_iam_role_policy" "task_s3" {
  name = "s3-mod-profiles"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["s3:GetObject", "s3:ListBucket"]
      Resource = [
        "arn:aws:s3:::${var.mod_bucket_name}",
        "arn:aws:s3:::${var.mod_bucket_name}/minecraft-mods/*",
        "arn:aws:s3:::${var.mod_bucket_name}/setup/*"
      ]
    }]
  })
}

resource "aws_ecs_task_definition" "minecraft" {
  family                   = "${var.project}-${var.environment}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 2048
  memory                   = 8192
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  volume {
    name = "minecraft-efs"

    efs_volume_configuration {
      file_system_id          = var.efs_id
      transit_encryption      = "ENABLED"
      authorization_config {
        access_point_id = var.efs_access_point_id
        iam             = "ENABLED"
      }
    }
  }

  container_definitions = jsonencode([{
    name      = "minecraft"
    image     = "${aws_ecr_repository.minecraft.repository_url}:latest"
    essential = true

    portMappings = [
      { containerPort = 25565, protocol = "tcp" },
      { containerPort = 25575, protocol = "tcp" }
    ]

    environment = [
      { name = "MOD_BUCKET", value = var.mod_bucket_name },
      { name = "JVM_MIN_MEM", value = var.jvm_min_mem },
      { name = "JVM_MAX_MEM", value = var.jvm_max_mem }
    ]

    secrets = [{
      name      = "RCON_PASSWORD"
      valueFrom = "arn:aws:ssm:${var.region}:${var.account_id}:parameter/minecraft/rcon-password"
    }]

    mountPoints = [{
      sourceVolume  = "minecraft-efs"
      containerPath = "/minecraft"
      readOnly      = false
    }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.minecraft.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "minecraft"
      }
    }
  }])
}

resource "aws_ecs_service" "minecraft" {
  name            = "${var.project}-${var.environment}-service"
  cluster         = aws_ecs_cluster.minecraft.id
  task_definition = aws_ecs_task_definition.minecraft.arn
  desired_count   = 0
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.public_subnet_ids
    security_groups  = [var.minecraft_sg_id]
    assign_public_ip = true
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  lifecycle {
    ignore_changes = [desired_count, task_definition]
  }
}
