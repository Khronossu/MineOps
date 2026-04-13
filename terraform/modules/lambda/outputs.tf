output "lambda_function_name" {
  value = aws_lambda_function.scaler.function_name
}

output "lambda_function_arn" {
  value = aws_lambda_function.scaler.arn
}

output "control_api_url" {
  value = aws_apigatewayv2_api.control.api_endpoint
}
