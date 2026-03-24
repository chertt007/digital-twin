#!/bin/bash
set -euo pipefail

if [ $# -eq 0 ]; then
  echo "Error: Environment parameter is required"
  echo "Usage: $0 <environment> [project_name]"
  echo "Example: $0 dev"
  exit 1
fi

ENVIRONMENT="$1"
PROJECT_NAME="${2:-twin}"

if [[ ! "$ENVIRONMENT" =~ ^(dev|test|prod)$ ]]; then
  echo "Error: Invalid environment '$ENVIRONMENT'"
  echo "Available environments: dev, test, prod"
  exit 1
fi

if [ -n "${GITHUB_ACTIONS:-}" ]; then
  # In GitHub Actions we rely on OIDC credentials from configure-aws-credentials.
  unset AWS_PROFILE AWS_DEFAULT_PROFILE
  echo "Using GitHub OIDC credentials"
else
  AWS_PROFILE="${AWS_PROFILE:-root}"
  export AWS_PROFILE
  export AWS_DEFAULT_PROFILE="$AWS_PROFILE"
  echo "Using AWS profile: ${AWS_PROFILE}"
fi

echo "Preparing to destroy ${PROJECT_NAME}-${ENVIRONMENT} infrastructure..."

cd "$(dirname "$0")/../terraform"

AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
AWS_REGION="${DEFAULT_AWS_REGION:-us-east-1}"

echo "Initializing Terraform with S3 backend..."
terraform init -input=false \
  -backend-config="bucket=twin-terraform-state-${AWS_ACCOUNT_ID}" \
  -backend-config="key=${ENVIRONMENT}/terraform.tfstate" \
  -backend-config="region=${AWS_REGION}" \
  -backend-config="dynamodb_table=twin-terraform-locks" \
  -backend-config="encrypt=true"

if ! terraform workspace list | grep -q "$ENVIRONMENT"; then
  echo "Error: Workspace '$ENVIRONMENT' does not exist"
  echo "Available workspaces:"
  terraform workspace list
  exit 1
fi

terraform workspace select "$ENVIRONMENT"

echo "Emptying S3 buckets..."
FRONTEND_BUCKET="${PROJECT_NAME}-${ENVIRONMENT}-frontend-${AWS_ACCOUNT_ID}"
MEMORY_BUCKET="${PROJECT_NAME}-${ENVIRONMENT}-memory-${AWS_ACCOUNT_ID}"

if aws s3 ls "s3://${FRONTEND_BUCKET}" >/dev/null 2>&1; then
  echo "  Emptying ${FRONTEND_BUCKET}..."
  aws s3 rm "s3://${FRONTEND_BUCKET}" --recursive
else
  echo "  Frontend bucket not found or already empty"
fi

if aws s3 ls "s3://${MEMORY_BUCKET}" >/dev/null 2>&1; then
  echo "  Emptying ${MEMORY_BUCKET}..."
  aws s3 rm "s3://${MEMORY_BUCKET}" --recursive
else
  echo "  Memory bucket not found or already empty"
fi

echo "Running terraform destroy..."

if [ ! -f "../backend/lambda-deployment.zip" ]; then
  echo "Creating dummy lambda package for destroy operation..."
  echo "dummy" | zip ../backend/lambda-deployment.zip -
fi

if [ "$ENVIRONMENT" = "prod" ] && [ -f "prod.tfvars" ]; then
  terraform destroy -var-file=prod.tfvars -var="project_name=${PROJECT_NAME}" -var="environment=${ENVIRONMENT}" -auto-approve
else
  terraform destroy -var="project_name=${PROJECT_NAME}" -var="environment=${ENVIRONMENT}" -auto-approve
fi

echo "Infrastructure for ${ENVIRONMENT} has been destroyed!"
echo ""
echo "To remove the workspace completely, run:"
echo "  terraform workspace select default"
echo "  terraform workspace delete ${ENVIRONMENT}"
