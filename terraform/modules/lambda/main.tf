data "aws_ssm_parameter" "cloudflare_token" {
  name            = "/minecraft/cloudflare-api-token"
  with_decryption = true
}

resource "aws_iam_role" "lambda" {
  name = "${var.project}-${var.environment}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_permissions" {
  name = "mineops-lambda-policy"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["ecs:UpdateService", "ecs:DescribeServices", "ecs:DescribeTasks", "ecs:ListTasks"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:PutParameter"]
        Resource = "arn:aws:ssm:${var.region}:${var.account_id}:parameter/minecraft/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = "arn:aws:s3:::${var.mod_bucket_name}"
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:DescribeNetworkInterfaces"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = "arn:aws:lambda:${var.region}:${var.account_id}:function:${var.project}-${var.environment}-scaler"
      }
    ]
  })
}

data "archive_file" "lambda" {
  type        = "zip"
  source_dir  = "${path.root}/../lambda/scaler"
  output_path = "${path.module}/lambda.zip"
}

resource "aws_lambda_function" "scaler" {
  function_name    = "${var.project}-${var.environment}-scaler"
  role             = aws_iam_role.lambda.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  timeout          = 300

  environment {
    variables = {
      ECS_CLUSTER          = var.ecs_cluster_name
      ECS_SERVICE          = var.ecs_service_name
      MOD_BUCKET           = var.mod_bucket_name
      CLOUDFLARE_ZONE_ID   = var.cloudflare_zone_id
      DOMAIN_NAME          = var.domain_name
      CLOUDFLARE_API_TOKEN = data.aws_ssm_parameter.cloudflare_token.value
      AWS_REGION_NAME      = var.region
    }
  }

  tags = {
    Name = "${var.project}-${var.environment}-scaler"
  }
}

resource "aws_cloudwatch_event_rule" "scale_down_check" {
  name                = "${var.project}-${var.environment}-scale-down-check"
  description         = "Check every 10 minutes if server should scale down"
  schedule_expression = "rate(10 minutes)"
}

resource "aws_cloudwatch_event_target" "scale_down_check" {
  rule      = aws_cloudwatch_event_rule.scale_down_check.name
  target_id = "ScaleDownCheck"
  arn       = aws_lambda_function.scaler.arn

  input = jsonencode({ action = "scale_down" })
}

resource "aws_lambda_permission" "eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.scaler.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.scale_down_check.arn
}

# HTTP API for the web control panel
resource "aws_apigatewayv2_api" "control" {
  name          = "${var.project}-${var.environment}-control"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["GET", "POST", "OPTIONS"]
    allow_headers = ["Content-Type"]
  }
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.control.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.scaler.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "start" {
  api_id    = aws_apigatewayv2_api.control.id
  route_key = "POST /start"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_route" "status" {
  api_id    = aws_apigatewayv2_api.control.id
  route_key = "GET /status"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.control.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.scaler.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.control.execution_arn}/*/*"
}
