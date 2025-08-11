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
* **Terraform**: `terraform/main.tf` + `variables.tf`

  * ECS cluster, task definition (with FireLens → New Relic), service (public IP), SG, IAM roles, CW log group
  * New Relic license key stored in **AWS Secrets Manager** and read by the task

---

## Prerequisites

1. **AWS account & IAM user/role** with permissions for ECS, IAM, EC2 (SG), CloudWatch Logs, Secrets Manager.
2. **New Relic account** **License Key**.

   
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
| `NEW_RELIC_LICENSE_KEY`       | New relic license key                        |

> The workflow also sets`TF_VAR_newrelic_region=EU` so Terraform knows how/where to send logs.

---

## How it works (high level)

1. **Lint & Leaks**

   * `gitleaks` scans for hardcoded secrets
   * `npm ci` + `npm run lint` (if a `lint` script exists)

2. **Build & Push Image**

   * Build with Buildx
   * Push to **Docker Hub**: `DockerUsername/node-hello:<tag>`

3. **Deploy with Terraform**

   * Creates ECS cluster + service (Fargate) + task definition
   * Security Group opens container port `3000` to the world
   * **public IP** you can open in a browser
   * FireLens sidecar (`newrelic/newrelic-fluentbit-output:latest`) sends logs to **New Relic Logs EU**

---


## Setup & Run

### 1) Fork/clone and push your app code

Make sure your app listens on **`PORT=3000`** (or update `container_port`).

### 2) Add the previously mentioned secrets

### 3) Push to `main`

Triggers the pipeline:

* `lint` → `build-and-push` → `terraform-apply`

### 4) Get the public IP

Because there’s no ALB, open the task’s public IP directly:

* AWS Console → **ECS → Clusters → `<name>-cluster` → Services → `<name>-svc` → Tasks → running task → “Public IP”**

Visit: `http://<PUBLIC_IP>:3000`

### 5) See logs in New Relic

* New Relic (EU) → **Logs**

---

## Local runs (optional)

If you want to try Terraform locally instead of GitHub Actions:

```bash
cd terraform
export AWS_REGION=eu-central-1
export TF_VAR_newrelic_region=EU
export TF_VAR_newrelic_license_key='<NR license>'
terraform init
terraform apply -auto-approve
```

---

## Destroying the stack

* **Via CLI (from `terraform/` dir with the same state):**

  ```bash
  terraform destroy -auto-approve
  ```

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