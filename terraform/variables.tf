variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "name" {
  description = "Base name for ECS resources"
  type        = string
  default     = "Nawy-App"
}

variable "image" {
  description = "Container image (e.g., ghcr.io/<owner>/node-hello:latest or <dockerhub-user>/node-hello:latest)"
  type        = string
  default     = "mohamedmagdy00/node-hello:latest"
}

variable "container_port" {
  description = "Container port to expose"
  type        = number
  default     = 3000
}

variable "task_cpu" {
  description = "Fargate task CPU units (256=0.25 vCPU)"
  type        = string
  default     = "256"
}

variable "task_memory" {
  description = "Fargate task memory (in MiB)"
  type        = string
  default     = "512"
}

variable "desired_count" {
  description = "Number of running tasks"
  type        = number
  default     = 1
}

# Which New Relic logs endpoint to use (US or EU)
variable "newrelic_region" {
  description = "New Relic region for logs endpoint (US or EU)"
  type        = string
  default     = "US"
  validation {
    condition     = contains(["US", "EU"], upper(var.newrelic_region))
    error_message = "newrelic_region must be US or EU."
  }
}

# The New Relic LICENSE key
variable "newrelic_license_key" {
  description = "New Relic ingest license key"
  type        = string
  sensitive   = true
}
