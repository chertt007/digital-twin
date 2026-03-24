param(
    [string]$Environment = "dev",   # dev | test | prod
    [string]$ProjectName = "twin",
    [string]$AwsProfile = "root"
)
$ErrorActionPreference = "Stop"

function Assert-LastExitCode([string]$Step) {
    if ($LASTEXITCODE -ne 0) {
        throw "$Step failed with exit code $LASTEXITCODE"
    }
}

Write-Host "Deploying $ProjectName to $Environment ..." -ForegroundColor Green
if ($AwsProfile -ne "root") {
    Write-Host "Overriding AWS profile '$AwsProfile' to 'root'." -ForegroundColor Yellow
    $AwsProfile = "root"
}
Write-Host "Using AWS profile: $AwsProfile" -ForegroundColor Cyan
$env:AWS_PROFILE = $AwsProfile
$env:AWS_DEFAULT_PROFILE = $AwsProfile

# 1. Build Lambda package
Set-Location (Split-Path $PSScriptRoot -Parent)   # project root
Write-Host "Building Lambda package..." -ForegroundColor Yellow
Set-Location backend
uv run deploy.py
Assert-LastExitCode "uv run deploy.py"
Set-Location ..

# 2. Terraform workspace & apply
Set-Location terraform
$awsAccountId = aws sts get-caller-identity --query Account --output text
$awsRegion = if ($env:DEFAULT_AWS_REGION) { $env:DEFAULT_AWS_REGION } else { "us-east-1" }
terraform init -input=false `
  -backend-config="bucket=twin-terraform-state-$awsAccountId" `
  -backend-config="key=$Environment/terraform.tfstate" `
  -backend-config="region=$awsRegion" `
  -backend-config="dynamodb_table=twin-terraform-locks" `
  -backend-config="encrypt=true"
Assert-LastExitCode "terraform init"

$workspaces = terraform workspace list
Assert-LastExitCode "terraform workspace list"

if (-not ($workspaces | Select-String $Environment)) {
    terraform workspace new $Environment
    Assert-LastExitCode "terraform workspace new"
}
else {
    terraform workspace select $Environment
    Assert-LastExitCode "terraform workspace select"
}

if ($Environment -eq "prod") {
    terraform apply -var-file="prod.tfvars" -var="project_name=$ProjectName" -var="environment=$Environment" -auto-approve
    Assert-LastExitCode "terraform apply (prod)"
}
else {
    terraform apply -var="project_name=$ProjectName" -var="environment=$Environment" -auto-approve
    Assert-LastExitCode "terraform apply"
}

$ApiUrl = terraform output -raw api_gateway_url
Assert-LastExitCode "terraform output api_gateway_url"
$FrontendBucket = terraform output -raw s3_frontend_bucket
Assert-LastExitCode "terraform output s3_frontend_bucket"
try {
    $CustomUrl = terraform output -raw custom_domain_url
    Assert-LastExitCode "terraform output custom_domain_url"
}
catch {
    $CustomUrl = ""
}

# 3. Build + deploy frontend
Set-Location ..\frontend

# Create production environment file with API URL
Write-Host "Setting API URL for production..." -ForegroundColor Yellow
"NEXT_PUBLIC_API_URL=$ApiUrl" | Out-File .env.production -Encoding utf8

npm install
Assert-LastExitCode "npm install"
npm run build
Assert-LastExitCode "npm run build"
aws s3 sync .\out "s3://$FrontendBucket/" --delete --no-verify-ssl
Assert-LastExitCode "aws s3 sync"
Set-Location ..

# 4. Final summary
$CfUrl = terraform -chdir=terraform output -raw cloudfront_url
Assert-LastExitCode "terraform output cloudfront_url"
Write-Host "Deployment complete!" -ForegroundColor Green
Write-Host "CloudFront URL : $CfUrl" -ForegroundColor Cyan
if ($CustomUrl) {
    Write-Host "Custom domain  : $CustomUrl" -ForegroundColor Cyan
}
Write-Host "API Gateway    : $ApiUrl" -ForegroundColor Cyan
