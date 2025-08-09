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

# --- Task definition ---
resource "aws_ecs_task_definition" "this" {
  family                   = "${var.name}-task"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.task_exec.arn

  container_definitions = jsonencode([
    {
      name      = "app",
      image     = var.image,                # e.g. ghcr.io/you/node-hello:latest
      essential = true,
      portMappings = [
        {
          containerPort = var.container_port,
          protocol      = "tcp"
        }
      ],
      environment = [
        { name = "PORT", value = tostring(var.container_port) }
      ],
      logConfiguration = {
        logDriver = "awslogs",
        options = {
          awslogs-region        = var.region,
          awslogs-group         = aws_cloudwatch_log_group.ecs.name,
          awslogs-stream-prefix = "ecs"
        }
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
