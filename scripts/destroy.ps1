param(
    [Parameter(Mandatory=$true)]
    [string]$Environment,
    [string]$ProjectName = "twin",
    [string]$AwsProfile = "root"
)

$ErrorActionPreference = "Stop"

function Assert-LastExitCode([string]$Step) {
    if ($LASTEXITCODE -ne 0) {
        throw "$Step failed with exit code $LASTEXITCODE"
    }
}

# Validate environment parameter
if ($Environment -notmatch '^(dev|test|prod)$') {
    Write-Host "Error: Invalid environment '$Environment'" -ForegroundColor Red
    Write-Host "Available environments: dev, test, prod" -ForegroundColor Yellow
    exit 1
}

Write-Host "Preparing to destroy $ProjectName-$Environment infrastructure..." -ForegroundColor Yellow

if ($env:GITHUB_ACTIONS -eq "true") {
    Write-Host "Using GitHub OIDC credentials" -ForegroundColor Cyan
    Remove-Item Env:AWS_PROFILE -ErrorAction SilentlyContinue
    Remove-Item Env:AWS_DEFAULT_PROFILE -ErrorAction SilentlyContinue
}
else {
    if ([string]::IsNullOrWhiteSpace($AwsProfile)) {
        $AwsProfile = "root"
    }
    Write-Host "Using AWS profile: $AwsProfile" -ForegroundColor Cyan
    $env:AWS_PROFILE = $AwsProfile
    $env:AWS_DEFAULT_PROFILE = $AwsProfile
}

# Navigate to terraform directory
Set-Location (Join-Path (Split-Path $PSScriptRoot -Parent) "terraform")

# Get AWS Account ID for backend configuration
$awsAccountId = aws sts get-caller-identity --query Account --output text
$awsAccountId = $awsAccountId.Trim()
$awsIdentity = aws sts get-caller-identity --output json
Assert-LastExitCode "aws sts get-caller-identity"
$awsRegion = if ($env:DEFAULT_AWS_REGION) { $env:DEFAULT_AWS_REGION } else { "us-east-1" }
Write-Host "AWS identity: $awsIdentity" -ForegroundColor Gray

# Initialize terraform with S3 backend
Write-Host "Initializing Terraform with S3 backend..." -ForegroundColor Yellow
terraform init -input=false `
  -backend-config="bucket=twin-terraform-state-$awsAccountId" `
  -backend-config="key=$Environment/terraform.tfstate" `
  -backend-config="region=$awsRegion" `
  -backend-config="dynamodb_table=twin-terraform-locks" `
  -backend-config="encrypt=true"
Assert-LastExitCode "terraform init"

# Check if workspace exists
$workspaces = terraform workspace list
Assert-LastExitCode "terraform workspace list"
if (-not ($workspaces | Select-String $Environment)) {
    Write-Host "Error: Workspace '$Environment' does not exist" -ForegroundColor Red
    Write-Host "Available workspaces:" -ForegroundColor Yellow
    terraform workspace list
    exit 1
}

# Select the workspace
terraform workspace select $Environment
Assert-LastExitCode "terraform workspace select"

Write-Host "Emptying S3 buckets..." -ForegroundColor Yellow

# Define bucket names with account ID (matching Day 4 naming)
$FrontendBucket = "$ProjectName-$Environment-frontend-$awsAccountId"
$MemoryBucket = "$ProjectName-$Environment-memory-$awsAccountId"

# Empty frontend bucket if it exists
aws s3 ls "s3://$FrontendBucket" 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Host "  Emptying $FrontendBucket..." -ForegroundColor Gray
    aws s3 rm "s3://$FrontendBucket" --recursive
    Assert-LastExitCode "aws s3 rm frontend bucket"
} else {
    Write-Host "  Frontend bucket not found or already empty" -ForegroundColor Gray
}

# Empty memory bucket if it exists
aws s3 ls "s3://$MemoryBucket" 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Host "  Emptying $MemoryBucket..." -ForegroundColor Gray
    aws s3 rm "s3://$MemoryBucket" --recursive
    Assert-LastExitCode "aws s3 rm memory bucket"
} else {
    Write-Host "  Memory bucket not found or already empty" -ForegroundColor Gray
}

Write-Host "Running terraform destroy..." -ForegroundColor Yellow

# Run terraform destroy with auto-approve
if ($Environment -eq "prod" -and (Test-Path "prod.tfvars")) {
    terraform destroy -var-file=prod.tfvars `
                     -var="project_name=$ProjectName" `
                     -var="environment=$Environment" `
                     -auto-approve
    Assert-LastExitCode "terraform destroy (prod)"
} else {
    terraform destroy -var="project_name=$ProjectName" `
                     -var="environment=$Environment" `
                     -auto-approve
    Assert-LastExitCode "terraform destroy"
}

Write-Host "Infrastructure for $Environment has been destroyed!" -ForegroundColor Green
Write-Host ""
Write-Host "  To remove the workspace completely, run:" -ForegroundColor Cyan
Write-Host "   terraform workspace select default" -ForegroundColor White
Write-Host "   terraform workspace delete $Environment" -ForegroundColor White
