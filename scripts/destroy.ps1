param(
    [ValidateSet("dev", "test", "prod")]
    [string]$Environment = "dev",
    [string]$ProjectName = "twin",
    [string]$AwsProfile = "root",
    [bool]$NoVerifySsl = $true
)
$ErrorActionPreference = "Continue"

function Assert-LastExitCode([string]$Step) {
    if ($LASTEXITCODE -ne 0) {
        throw "$Step failed with exit code $LASTEXITCODE"
    }
}

function Test-S3BucketExists([string]$BucketName, [string[]]$AwsArgs) {
    & aws @AwsArgs s3api head-bucket --bucket $BucketName 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Clear-S3Bucket([string]$BucketName, [string[]]$AwsArgs) {
    if ([string]::IsNullOrWhiteSpace($BucketName)) {
        return
    }

    if (-not (Test-S3BucketExists -BucketName $BucketName -AwsArgs $AwsArgs)) {
        Write-Host "  Bucket $BucketName not found or already deleted" -ForegroundColor Gray
        return
    }

    Write-Host "  Emptying $BucketName..." -ForegroundColor Gray
    & aws @AwsArgs s3 rm "s3://$BucketName" --recursive 2>$null
    Assert-LastExitCode "aws s3 rm $BucketName"
}

$projectRoot = Split-Path $PSScriptRoot -Parent
$terraformDir = Join-Path $projectRoot "terraform"
$awsArgs = @()
if ($NoVerifySsl) {
    $awsArgs += "--no-verify-ssl"
}

Write-Host "Preparing to destroy $ProjectName-$Environment infrastructure..." -ForegroundColor Yellow
Write-Host "Using AWS profile: $AwsProfile" -ForegroundColor Cyan
if ($NoVerifySsl) {
    Write-Host "AWS CLI SSL verification is disabled for this run (--no-verify-ssl)." -ForegroundColor Yellow
    $env:PYTHONWARNINGS = "ignore:Unverified HTTPS request"
}

$env:AWS_PROFILE = $AwsProfile
$env:AWS_DEFAULT_PROFILE = $AwsProfile

Push-Location $terraformDir
try {
    terraform init -input=false
    Assert-LastExitCode "terraform init"

    $workspaces = terraform workspace list
    Assert-LastExitCode "terraform workspace list"
    if (-not ($workspaces | Select-String -SimpleMatch $Environment)) {
        Write-Host "Error: Workspace '$Environment' does not exist" -ForegroundColor Red
        Write-Host "Available workspaces:" -ForegroundColor Yellow
        terraform workspace list
        Assert-LastExitCode "terraform workspace list"
        exit 1
    }

    terraform workspace select $Environment
    Assert-LastExitCode "terraform workspace select"

    Write-Host "Checking AWS CLI access..." -ForegroundColor Yellow
    $awsAccountIdRaw = & aws @AwsArgs sts get-caller-identity --query Account --output text 2>$null
    Assert-LastExitCode "aws sts get-caller-identity"
    $awsAccountId = "$awsAccountIdRaw".Trim()
    if ([string]::IsNullOrWhiteSpace($awsAccountId)) {
        throw "aws sts get-caller-identity returned empty account id"
    }

    Write-Host "Emptying S3 buckets..." -ForegroundColor Yellow
    $frontendBucket = "$ProjectName-$Environment-frontend-$awsAccountId"
    $memoryBucket = "$ProjectName-$Environment-memory-$awsAccountId"

    Clear-S3Bucket -BucketName $frontendBucket -AwsArgs $awsArgs
    Clear-S3Bucket -BucketName $memoryBucket -AwsArgs $awsArgs

    Write-Host "Running terraform destroy..." -ForegroundColor Yellow
    if ($Environment -eq "prod" -and (Test-Path "prod.tfvars")) {
        terraform destroy -var-file="prod.tfvars" -var="project_name=$ProjectName" -var="environment=$Environment" -auto-approve
        Assert-LastExitCode "terraform destroy (prod)"
    }
    else {
        terraform destroy -var="project_name=$ProjectName" -var="environment=$Environment" -auto-approve
        Assert-LastExitCode "terraform destroy"
    }

    Write-Host "Infrastructure for $Environment has been destroyed!" -ForegroundColor Green
    Write-Host ""
    Write-Host "  To remove the workspace completely, run:" -ForegroundColor Cyan
    Write-Host "   terraform workspace select default" -ForegroundColor White
    Write-Host "   terraform workspace delete $Environment" -ForegroundColor White
}
catch {
    Write-Host "Destroy failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Tip: if your network injects TLS certificates, use AWS_CA_BUNDLE or keep -NoVerifySsl true." -ForegroundColor Yellow
    exit 1
}
finally {
    Pop-Location
}
