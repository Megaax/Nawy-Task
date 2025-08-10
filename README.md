# CI/CD + Terraform + ECS Fargate with New Relic Logs

This repo ships a minimal pipeline that:

* Lints the Node app and scans for leaked secrets (Gitleaks)
* Builds a Docker image and pushes to **Docker Hub** 
* Applies **Terraform** to deploy on **AWS ECS Fargate**
* Routes container logs to **New Relic** via **FireLens (Fluent Bit)**

---

## What’s included

* **GitHub Actions** workflow: `.github/workflows/ci-cd.yml`

  * Jobs: `lint` → `build-and-push` → `terraform-apply`
  * Gitleaks secret scan, npm lint, Docker Buildx, push to DockerHub, Terraform init/plan/apply
* **Terraform**: `terraform/main.tf` (+ your `variables.tf`)

  * ECS cluster, task definition (with FireLens → New Relic), service (public IP), SG, IAM roles, CW log group
  * New Relic license key stored in **AWS Secrets Manager** and read by the task

---

## Prerequisites

1. **AWS account & IAM user/role** with permissions for ECS, IAM, EC2 (SG), CloudWatch Logs, Secrets Manager.
2. **New Relic account** (EU region in this setup) with an **Ingest License Key**.

   * New Relic → **Account settings → API keys → “Ingest – License”**
3. **Docker Hub Container Registry** (Docker Hub) access 

---

## Required GitHub repository secrets

Add these in **Settings → Secrets and variables → Actions**:

| Secret                  | What it’s used for                                        |
| ----------------------- | --------------------------------------------------------- |
| `AWS_ACCESS_KEY_ID`     | Terraform & AWS actions auth                              |
| `AWS_SECRET_ACCESS_KEY` | Terraform & AWS actions auth                              |
| `AWS_REGION`            | (Optional) Defaults to `eu-central-1` in the workflow env |
| `NEW_RELIC_LICENSE_KEY` | New Relic ingest license key used by FireLens             |
| `DOCKERHUB_USERNAME`    | If you also push to Docker Hub                 |
| `DOCKERHUB_TOKEN`       | Docker Hub access token                        |

> The workflow also sets `TF_VAR_newrelic_license_key` and `TF_VAR_newrelic_region=EU` so Terraform knows how/where to send logs.

---

## How it works (high level)

1. **Lint & Leaks**

   * `gitleaks` scans for hardcoded secrets
   * `npm ci` + `npm run lint` (if you have a `lint` script)

2. **Build & Push Image**

   * Build with Buildx
   * Push to **Docker Hub**: `DockerUsername/node-hello:<tag>`

3. **Deploy with Terraform**

   * Creates ECS cluster + service (Fargate) + task definition
   * Security Group opens container port `3000` to the world
   * **public IP** you can open in a browser
   * FireLens sidecar (`newrelic/newrelic-fluentbit-output:latest`) sends logs to **New Relic Logs EU** via your license key

---

## File snippets you provided (for reference)

### `.github/workflows/ci-cd.yml` (excerpt)

* Gitleaks, lint, build & push, Terraform apply
* Sets:

  ```yaml
  env:
    AWS_REGION: ${{ secrets.AWS_REGION || 'eu-central-1' }}
    TF_VAR_newrelic_license_key: ${{ secrets.NEW_RELIC_LICENSE_KEY }}
    TF_VAR_newrelic_region: EU
  ```

### `terraform/main.tf` (key parts)

* FireLens container:

  ```hcl
  image = "newrelic/newrelic-fluentbit-output:latest"
  ```
* App logs to New Relic:

  ```hcl
  logConfiguration = {
    logDriver = "awsfirelens"
    options = {
      Name        = "newrelic"
      endpoint    = local.newrelic_endpoint   # EU/US picked by var
      compress    = "gzip"
      Retry_Limit = "2"
    }
    secretOptions = [
      { name = "licenseKey", valueFrom = aws_secretsmanager_secret.newrelic_license.arn }
    ]
  }
  ```
* New Relic endpoint selector:

  ```hcl
  locals {
    newrelic_endpoint = upper(var.newrelic_region) == "EU"
      ? "https://log-api.eu.newrelic.com/log/v1"
      : "https://log-api.newrelic.com/log/v1"
  }
  ```
* Secret in Secrets Manager:

  ```hcl
  resource "aws_secretsmanager_secret" "newrelic_license" {
    name = "${var.name}-newrelic-license-01"
  }
  resource "aws_secretsmanager_secret_version" "newrelic_license" {
    secret_id     = aws_secretsmanager_secret.newrelic_license.id
    secret_string = var.newrelic_license_key
  }
  ```
* Permissions: both **execution role** and **task role** can read the secret (execution role is required for `secretOptions`).

---

## Setup & Run

### 1) Fork/clone and push your app code

Make sure your app listens on **`PORT=3000`** (or update `container_port`).

### 2) Add Docker Hub secrets

### 3) Push to `main`

Triggers the pipeline:

* `lint` → `build-and-push` → `terraform-apply`

### 4) Get the public IP

Because there’s no ALB, open the task’s public IP directly:

* AWS Console → **ECS → Clusters → `<name>-cluster` → Services → `<name>-svc` → Tasks → running task → “Public IP”**
* Or CLI:

  ```bash
  aws ecs list-tasks --cluster Nawy-App-cluster --service-name Nawy-App-svc --query 'taskArns[0]' --output text \
  | xargs -I {} aws ecs describe-tasks --cluster Nawy-App-cluster --tasks {} \
    --query "tasks[0].attachments[0].details[?name=='publicIPv4Address'].value" --output text
  ```

Visit: `http://<PUBLIC_IP>:3000`

### 5) See logs in New Relic

* New Relic (EU) → **Logs**
* Filter by the log group prefix or message text from your app.
* If nothing appears, see **Troubleshooting** below.

---

## Local runs (optional)

If you want to try Terraform locally instead of GitHub Actions:

```bash
cd terraform
export AWS_REGION=eu-central-1
export TF_VAR_newrelic_region=EU
export TF_VAR_newrelic_license_key='<your NR license>'
terraform init
terraform apply -auto-approve
```

---

## Destroying the stack

> **Important:** If you run `terraform destroy` from a different machine without the same state, Terraform won’t know what to delete. Use the same state backend you applied with (consider S3 + DynamoDB for remote state in production).

* **Via CLI (from `terraform/` dir with the same state):**

  ```bash
  terraform destroy -auto-approve
  ```
If you don’t have the state anymore, use the AWS CLI cleanup script approach (delete service → task defs → cluster → SG → log group → IAM role → secret).

---

## Notes & Best Practices

* **State backend**: For team environments, we need to configure Terraform S3 backend + DynamoDB locking.
* **Zero-downtime**: Without ALB there’s no load balancing or stable DNS. For production: ALB/NLB + Route 53 + HTTPS.
* **Cost**: Fargate + public IP (no ALB) is cheap for demos; ALB adds cost.
* **Tagging/metadata**: Consider adding environment/service labels to logs for better queries in New Relic.

---

## Quick Reference

* **Workflow**: `.github/workflows/ci-cd.yml`
* **Terraform**: `terraform/main.tf`, `terraform/variables.tf`
* **Image**: `<dockerhub-user>/node-hello:<tag>`
* **App URL**: `http://<task-public-ip>:3000`
* **Logs**: New Relic (EU) → Logs (search by recent messages or container name)