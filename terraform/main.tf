terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

# --- Use default VPC & its subnets (default VPC subnets are public) ---
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default_vpc_subnets" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# --- ECS cluster ---
resource "aws_ecs_cluster" "this" {
  name = "${var.name}-cluster"
}

# --- CloudWatch Logs group ---
resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/${var.name}"
  retention_in_days = 7
}

# --- Task execution role (pull image, push logs) ---
data "aws_iam_policy_document" "ecs_task_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "task_exec" {
  name               = "${var.name}-task-exec"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume.json
}

resource "aws_iam_role_policy_attachment" "task_exec_policy" {
  role       = aws_iam_role.task_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# --- Task role (read NR license from Secrets Manager) ---
resource "aws_iam_role" "task_role" {
  name               = "${var.name}-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume.json
}

# Allow the EXECUTION role to read the New Relic license secret
data "aws_iam_policy_document" "exec_secrets_policy" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.newrelic_license.arn]
  }
}

resource "aws_iam_policy" "exec_secrets" {
  name   = "${var.name}-exec-secrets"
  policy = data.aws_iam_policy_document.exec_secrets_policy.json
}

resource "aws_iam_role_policy_attachment" "exec_secrets_attach" {
  role       = aws_iam_role.task_exec.name
  policy_arn = aws_iam_policy.exec_secrets.arn
}


data "aws_iam_policy_document" "task_secrets_policy" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.newrelic_license.arn]
  }
}

resource "aws_iam_policy" "task_secrets" {
  name   = "${var.name}-task-secrets"
  policy = data.aws_iam_policy_document.task_secrets_policy.json
}

resource "aws_iam_role_policy_attachment" "task_secrets_attach" {
  role       = aws_iam_role.task_role.name
  policy_arn = aws_iam_policy.task_secrets.arn
}


# --- Security group (open container port to the world) ---
resource "aws_security_group" "svc" {
  name        = "${var.name}-sg"
  description = "Allow inbound app traffic"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "App port"
    from_port   = var.container_port
    to_port     = var.container_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# # --- Task definition ---
# resource "aws_ecs_task_definition" "this" {
#   family                   = "${var.name}-task"
#   requires_compatibilities = ["FARGATE"]
#   network_mode             = "awsvpc"
#   cpu                      = var.task_cpu
#   memory                   = var.task_memory
#   execution_role_arn       = aws_iam_role.task_exec.arn

#   container_definitions = jsonencode([
#     {
#       name      = "app",
#       image     = var.image,
#       essential = true,
#       portMappings = [
#         {
#           containerPort = var.container_port,
#           protocol      = "tcp"
#         }
#       ],
#       environment = [
#         { name = "PORT", value = tostring(var.container_port) }
#       ],
#       logConfiguration = {
#         logDriver = "awslogs",
#         options = {
#           awslogs-region        = var.region,
#           awslogs-group         = aws_cloudwatch_log_group.ecs.name,
#           awslogs-stream-prefix = "ecs"
#         }
#       }
#     }
#   ])
# }

# --- Task definition (with FireLens -> New Relic) ---
resource "aws_ecs_task_definition" "this" {
  family                   = "${var.name}-task"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.task_exec.arn
  task_role_arn            = aws_iam_role.task_role.arn

  container_definitions = jsonencode([
    # FireLens log router (Fluent Bit)
    {
      name      = "log_router"
      image     = "newrelic/fluently-bit:latest"
      essential = true
      firelensConfiguration = {
        type    = "fluentbit"
        options = { enable-ecs-log-metadata = "true" }
      }
      # Router's own logs go to CloudWatch for troubleshooting
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-region        = var.region
          awslogs-group         = aws_cloudwatch_log_group.ecs.name
          awslogs-stream-prefix = "firelens"
        }
      }
    },

    # Your application container
    {
      name      = "app"
      image     = var.image
      essential = true
      portMappings = [
        { containerPort = var.container_port, protocol = "tcp" }
      ]
      environment = [
        { name = "PORT", value = tostring(var.container_port) }
      ]
      # Send app logs to New Relic via FireLens
      logConfiguration = {
        logDriver = "awsfirelens"
        options = {
          Name        = "newrelic"
          endpoint    = local.newrelic_endpoint
          compress    = "gzip"
          Retry_Limit = "2"
        }
        secretOptions = [
          { name = "licenseKey", valueFrom = aws_secretsmanager_secret.newrelic_license.arn }
        ]
      }
    }
  ])

}

# --- Service with public IP (no ALB) ---
resource "aws_ecs_service" "this" {
  name            = "${var.name}-svc"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = data.aws_subnets.default_vpc_subnets.ids
    assign_public_ip = true
    security_groups  = [aws_security_group.svc.id]
  }

  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100
}

locals {
  newrelic_endpoint = upper(var.newrelic_region) == "EU" ? "https://log-api.eu.newrelic.com/log/v1" : "https://log-api.newrelic.com/log/v1"
}

resource "aws_secretsmanager_secret" "newrelic_license" {
  name = "${var.name}-newrelic-license-7"
}

resource "aws_secretsmanager_secret_version" "newrelic_license" {
  secret_id     = aws_secretsmanager_secret.newrelic_license.id
  secret_string = var.newrelic_license_key
}
