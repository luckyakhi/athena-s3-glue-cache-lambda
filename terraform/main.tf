############################################
# Serverless POC: API Gateway -> Lambda (in VPC) -> Redis (ElastiCache) -> Athena/S3 via VPC Endpoints
############################################
terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 5.50" }
  }
}

provider "aws" {
  region = var.region
  assume_role {
    role_arn     = "arn:aws:iam::273505519511:role/TerraformProvisioner"
    session_name = "tf-setup"
  }
}

variable "region"      { default = "ap-south-1" }
variable "name_prefix" { default = "demoaks" }

data "aws_caller_identity" "me" {}
data "aws_region" "current" {}

# VPC (no NAT/IGW), two private subnets
resource "aws_vpc" "main" {
  cidr_block           = "10.42.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "${var.name_prefix}-vpc" }
}

resource "aws_subnet" "private_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.42.1.0/24"
  availability_zone = "${var.region}a"
  tags = { Name = "${var.name_prefix}-priv-a" }
}

resource "aws_subnet" "private_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.42.2.0/24"
  availability_zone = "${var.region}b"
  tags = { Name = "${var.name_prefix}-priv-b" }
}

# S3 buckets
resource "aws_s3_bucket" "data" {
  bucket        = "${var.name_prefix}-data-${data.aws_caller_identity.me.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket" "athena_results" {
  bucket        = "${var.name_prefix}-athena-results-${data.aws_caller_identity.me.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id
  rule {
    id     = "expire-results"
    status = "Enabled"
    expiration { days = 3 }
    filter {}
  }
}

# Glue DB + Table
resource "aws_glue_catalog_database" "db" { name = "${var.name_prefix}_demo_db" }

resource "aws_glue_catalog_table" "table" {
  name          = "demo_table"
  database_name = aws_glue_catalog_database.db.name
  table_type    = "EXTERNAL_TABLE"

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.data.bucket}/parquet/"
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"
    ser_de_info {
      name                  = "ParquetHiveSerDe"
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
      parameters = { "serialization.format" = "1" }
    }
    columns {
      name = "id"
      type = "int"
    }
    columns {
      name = "name"
      type = "string"
    }
    columns {
      name = "value"
      type = "double"
    }
  }
  parameters = { EXTERNAL = "TRUE", classification = "parquet", "parquet.compression" = "SNAPPY" }
}

# Athena workgroup
resource "aws_athena_workgroup" "wg" {
  name = "${var.name_prefix}_wg"
  configuration {
    enforce_workgroup_configuration = true
    result_configuration {
      output_location = "s3://${aws_s3_bucket.athena_results.bucket}/results/"
      encryption_configuration { encryption_option = "SSE_S3" }
    }
  }
  state = "ENABLED"
}

# SGs
resource "aws_security_group" "lambda" {
  name   = "${var.name_prefix}-lambda-sg"
  vpc_id = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
resource "aws_security_group" "redis" {
  name   = "${var.name_prefix}-redis-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Redis serverless
resource "aws_elasticache_serverless_cache" "redis" {
  engine               = "redis"
  name                 = "${var.name_prefix}-redis"
  subnet_ids           = [aws_subnet.private_a.id, aws_subnet.private_b.id]
  security_group_ids   = [aws_security_group.redis.id]
  major_engine_version = "7"

  cache_usage_limits {
    data_storage {
      maximum = 1
      unit    = "GB"
    }

    ecpu_per_second {
      maximum = 1000
    }
  }
}

# VPC Endpoints
resource "aws_security_group" "vpce" {
  name   = "${var.name_prefix}-vpce-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# S3 Gateway endpoint (no routes used here; Lambda SDK uses S3 via VPC gateway)
resource "aws_vpc_endpoint" "s3" {
  vpc_id           = aws_vpc.main.id
  service_name     = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type= "Gateway"
}

locals { interface_services = ["athena","glue","logs","sts"] }
resource "aws_vpc_endpoint" "interfaces" {
  for_each           = toset(local.interface_services)
  vpc_id             = aws_vpc.main.id
  service_name       = "com.amazonaws.${var.region}.${each.value}"
  vpc_endpoint_type  = "Interface"
  subnet_ids         = [aws_subnet.private_a.id] # 1 AZ to reduce cost
  security_group_ids = [aws_security_group.vpce.id]
  private_dns_enabled = true
}

# IAM for Lambda
resource "aws_iam_role" "lambda" {
  name = "${var.name_prefix}-lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{ Effect="Allow", Principal={ Service="lambda.amazonaws.com" }, Action="sts:AssumeRole" }]
  })
}
resource "aws_iam_role_policy" "lambda_inline" {
  name = "${var.name_prefix}-lambda-inline"
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version="2012-10-17",
    Statement=[
      { Effect="Allow", Action=["athena:*","glue:GetDatabase","glue:GetTable","glue:GetPartitions"], Resource="*" },
      { Effect="Allow", Action=["s3:*"], Resource=[
        aws_s3_bucket.data.arn,"${aws_s3_bucket.data.arn}/*",
        aws_s3_bucket.athena_results.arn,"${aws_s3_bucket.athena_results.arn}/*"
      ]},
      { Effect="Allow", Action=["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"], Resource="*" }
    ]
  })
}

# Lambda function
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/../lambda/handler.py"
  output_path = "${path.module}/../lambda/lambda.zip"
}

resource "aws_lambda_function" "proxy" {
  function_name = "${var.name_prefix}-athena-proxy"
  role          = aws_iam_role.lambda.arn
  handler       = "handler.handler"
  runtime       = "python3.12"
  filename      = data.archive_file.lambda_zip.output_path
  memory_size   = 256
  timeout       = 60

  environment {
    variables = {
      AWS_REGION  = var.region
      ATHENA_WG   = aws_athena_workgroup.wg.name
      GLUE_DB     = aws_glue_catalog_database.db.name
      S3_OUTPUT   = "s3://${aws_s3_bucket.athena_results.bucket}/results/"
      REDIS_HOST  = aws_elasticache_serverless_cache.redis.endpoint[0].address
      REDIS_PORT  = "6379"
      CACHE_TTL   = "300"
    }
  }

  vpc_config {
    subnet_ids         = [aws_subnet.private_a.id, aws_subnet.private_b.id]
    security_group_ids = [aws_security_group.lambda.id]
  }
}

# API Gateway HTTP API
resource "aws_apigatewayv2_api" "http" {
  name          = "${var.name_prefix}-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.http.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.proxy.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "query" {
  api_id    = aws_apigatewayv2_api.http.id
  route_key = "POST /query"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_lambda_permission" "api_invoke" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.proxy.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http.execution_arn}/*/*"
}

resource "aws_apigatewayv2_stage" "prod" {
  api_id      = aws_apigatewayv2_api.http.id
  name        = "$default"
  auto_deploy = true
}

# Outputs
output "api_endpoint"           { value = aws_apigatewayv2_api.http.api_endpoint }
output "data_bucket"            { value = aws_s3_bucket.data.bucket }
output "athena_results_bucket"  { value = aws_s3_bucket.athena_results.bucket }
output "athena_workgroup"       { value = aws_athena_workgroup.wg.name }
output "glue_db"                { value = aws_glue_catalog_database.db.name }
output "redis_endpoint"         { value = aws_elasticache_serverless_cache.redis.endpoint[0].address }
