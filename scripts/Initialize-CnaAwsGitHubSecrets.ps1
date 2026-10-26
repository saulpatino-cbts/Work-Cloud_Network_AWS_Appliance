<#
.SYNOPSIS
Creates the AWS-side prerequisites the appliance's workflows need and records
them as GitHub secrets and variables (REVIEW.md R-001 – R-003, TODO.md T-112).

.DESCRIPTION
The AWS counterpart of the Azure appliance's Initialize-CnaGitHubSecrets.ps1,
scoped to what is AWS-specific. In the account the AWS CLI is signed in to it
ensures, idempotently:

  1. The GitHub OIDC identity provider (token.actions.githubusercontent.com).
  2. The environment's deploy role, <project>-<env>-<region_short>-github-deploy,
     with the SAME trust policy the identity module declares (audience
     sts.amazonaws.com, subject repo:<owner>/<repo>:*), the three assessment
     reader policies the module attaches (ReadOnlyAccess, SecurityAudit,
     AWSBillingReadOnlyAccess) and an INLINE bootstrap deploy-write policy that
     mirrors the module's managed policy so the first Terraform apply can run.
     Terraform ignores inline policies it does not declare, so the two never
     fight; once the module's managed policy is attached by that first apply,
     re-run with -RemoveBootstrapPolicy to drop the inline copy.
  3. The Terraform state backend: a versioned, SSE-KMS, public-access-blocked
     S3 bucket and a DynamoDB lock table with a LockID (S) partition key —
     the four -backend-config values REVIEW.md R-002 describes.
  4. The GitHub side: the dev / prod / hub environments, the AWS_DEPLOY_ROLE_ARN
     secret (environment-scoped, plus repo-scoped if absent so the repo-level
     workflows 000/100 have one) and the TFSTATE_BUCKET, TFSTATE_LOCK_TABLE,
     AWS_REGION and AWS_REGION_SHORT repository variables.

The OIDC provider and the deploy role are ALSO declared by
infra/terraform/modules/identity. Creating them here first is what lets CI
authenticate at all; the script prints the `terraform import` commands that
hand them to Terraform so the first apply adopts rather than duplicates them.

Secrets policy: this script never reads, prints or stores a credential value.
Cloud access is the operator's `aws` CLI session; GitHub access is `gh`. The
cloud-agnostic secrets the README lists (Docker Hub, the Entra sign-in app,
the runtime secrets of R-008) are entered separately — they are not AWS-side.

.PARAMETER Repo
GitHub repository in owner/name form. Defaults to the repository `gh` resolves
from the current directory.

.PARAMETER Environment
Which environment's deploy role to create: dev or prod. Run once per
environment; the state backend and repository variables are shared and are
only created on the first run.

.PARAMETER ProjectName
Terraform var.project_name; first segment of every resource name.

.PARAMETER Region
AWS region for the state backend and the environment (Terraform var.region).

.PARAMETER RegionShort
Short region code used in resource names (Terraform var.region_short).

.PARAMETER TfstateBucket
S3 bucket for Terraform state. Globally unique; defaults to
<project>-tfstate-<account-id>-<region_short>.

.PARAMETER TfstateLockTable
DynamoDB table for state locking. Same default as workflow 000's input.

.PARAMETER AwsProfile
Named AWS CLI profile to use instead of the default credential chain.

.PARAMETER RemoveBootstrapPolicy
After the first successful Terraform apply has attached the module's managed
deploy-write policy: delete the inline bootstrap copy from the role and exit.

.PARAMETER SkipGitHub
Create the AWS resources only; do not touch GitHub secrets, variables or
environments.

.PARAMETER ReportDirectory
Where the JSON run report is written (gitignored). No credential value is
ever included.

.EXAMPLE
./scripts/Initialize-CnaAwsGitHubSecrets.ps1 -Environment dev -Region us-east-1 -RegionShort use1

.EXAMPLE
./scripts/Initialize-CnaAwsGitHubSecrets.ps1 -Environment prod -AwsProfile cna-prod -WhatIf

.EXAMPLE
# After the first 210 apply has attached the Terraform-managed deploy-write policy:
./scripts/Initialize-CnaAwsGitHubSecrets.ps1 -Environment dev -RemoveBootstrapPolicy
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Repo,

    [ValidateSet("dev", "prod")]
    [string]$Environment = "dev",

    [string]$ProjectName = "cna",

    # Your AWS region. No default on purpose, so no region is ever assumed for
    # you. Pass -Region, or leave it blank and the script will ask.
    # AWS Regions: https://docs.aws.amazon.com/global-infrastructure/latest/regions/aws-regions.html
    [string]$Region = "",

    # Short lowercase code for your region (e.g. use1 for us-east-1), used in
    # resource names. No default on purpose. Pass -RegionShort, or leave it blank
    # and the script will ask.
    [string]$RegionShort = "",

    [string]$TfstateBucket = "",

    [string]$TfstateLockTable = "cna-tfstate-lock",

    [string]$AwsProfile = "",

    [switch]$RemoveBootstrapPolicy,

    [switch]$SkipGitHub,

    [string]$ReportDirectory = ".reports/bootstrap"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Write-Step { param([string]$Message) Write-Host ""; Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok { param([string]$Message) Write-Host "    [OK] $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "    [!] $Message" -ForegroundColor Yellow }
function Write-Info { param([string]$Message) Write-Host "    [INFO] $Message" -ForegroundColor DarkCyan }

function Assert-Command {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "$Name CLI not found. Install it and rerun this script."
    }
}

# Every AWS CLI call goes through here so the profile/region are applied once
# and JSON output is parsed uniformly. $AllowFailure returns $null instead of
# throwing, for existence probes.
function Invoke-Aws {
    param(
        [string[]]$Arguments,
        [switch]$AllowFailure,
        [switch]$NoOutput
    )
    $args = @($Arguments) + @("--region", $Region, "--output", "json")
    if (-not [string]::IsNullOrWhiteSpace($AwsProfile)) { $args += @("--profile", $AwsProfile) }
    $raw = & aws @args 2>&1
    if ($LASTEXITCODE -ne 0) {
        if ($AllowFailure) { return $null }
        throw "aws $($Arguments -join ' ') failed: $raw"
    }
    if ($NoOutput -or [string]::IsNullOrWhiteSpace(($raw | Out-String))) { return $null }
    return (($raw | Out-String) | ConvertFrom-Json)
}

# Existence probe for calls that return no body (head-bucket): success or not.
function Test-AwsCall {
    param([string[]]$Arguments)
    $args = @($Arguments) + @("--region", $Region)
    if (-not [string]::IsNullOrWhiteSpace($AwsProfile)) { $args += @("--profile", $AwsProfile) }
    & aws @args 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Write-TempJson {
    param([object]$Document)
    $path = [System.IO.Path]::GetTempFileName()
    $Document | ConvertTo-Json -Depth 10 | Set-Content -Path $path -Encoding UTF8
    return $path
}

# IAM validates the OIDC provider's thumbprint list on create even though it
# no longer relies on it for GitHub's issuer (it trusts the public root CAs).
# Compute the real root-CA SHA-1 from a TLS handshake rather than pasting a
# stale or placeholder value.
function Get-GitHubOidcRootThumbprint {
    $hostName = "token.actions.githubusercontent.com"
    $script:__cnaChainRoot = $null
    $client = [System.Net.Sockets.TcpClient]::new($hostName, 443)
    try {
        $callback = [System.Net.Security.RemoteCertificateValidationCallback]{
            param($sender, $certificate, $chain, $errors)
            if ($chain -and $chain.ChainElements.Count -gt 0) {
                $script:__cnaChainRoot = $chain.ChainElements[$chain.ChainElements.Count - 1].Certificate
            }
            return $true
        }
        $ssl = [System.Net.Security.SslStream]::new($client.GetStream(), $false, $callback)
        try {
            $ssl.AuthenticateAsClient($hostName)
        } finally {
            $ssl.Dispose()
        }
    } finally {
        $client.Dispose()
    }
    $chainRoot = $script:__cnaChainRoot
    if (-not $chainRoot) { throw "Could not read the TLS certificate chain for $hostName." }
    return $chainRoot.GetCertHashString().ToLowerInvariant()
}

function Invoke-Gh {
    param([string[]]$Arguments)
    $out = & gh @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "gh $($Arguments -join ' ') failed: $out" }
    return $out
}

function Set-GitHubVariable {
    param([string]$RepoName, [string]$Name, [string]$Value)
    if ($PSCmdlet.ShouldProcess("$RepoName variable $Name", "set")) {
        Invoke-Gh -Arguments @("variable", "set", $Name, "--repo", $RepoName, "--body", $Value) | Out-Null
    }
    Write-Ok "Variable $Name = $Value"
}

function Set-GitHubSecretValue {
    # Only ever used for the deploy role ARN, which is not a credential but is
    # stored as a secret because every workflow reads it as one.
    param([string]$RepoName, [string]$Name, [string]$Value, [string]$EnvironmentName = "")
    $target = if ($EnvironmentName) { "$RepoName environment $EnvironmentName secret $Name" } else { "$RepoName secret $Name" }
    if ($PSCmdlet.ShouldProcess($target, "set")) {
        if ($EnvironmentName) {
            $Value | gh secret set $Name --repo $RepoName --env $EnvironmentName | Out-Null
        } else {
            $Value | gh secret set $Name --repo $RepoName | Out-Null
        }
        if ($LASTEXITCODE -ne 0) { throw "gh secret set $Name failed." }
    }
    Write-Ok "Secret $Name set ($(if ($EnvironmentName) { "environment $EnvironmentName" } else { 'repository' }))"
}

function Confirm-GitHubEnvironment {
    param([string]$RepoName, [string]$Name)
    $existing = & gh api "repos/$RepoName/environments/$Name" --jq .name 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($existing)) {
        Write-Ok "Environment exists: $Name"
        return
    }
    if ($PSCmdlet.ShouldProcess("$RepoName environment $Name", "create")) {
        Invoke-Gh -Arguments @("api", "-X", "PUT", "repos/$RepoName/environments/$Name") | Out-Null
    }
    Write-Ok "Created environment: $Name"
}

# ─── Preflight ────────────────────────────────────────────────────────────────
Write-Step "Checking prerequisites"
Assert-Command aws
if (-not $SkipGitHub) { Assert-Command gh }

# Region is never assumed for you. If you did not pass -Region / -RegionShort,
# ask now, before any AWS call uses it. These feed resource names, the S3 state
# bucket and the AWS_REGION / AWS_REGION_SHORT GitHub variables below.
Write-Step "Choosing your AWS region"
while ([string]::IsNullOrWhiteSpace($Region)) {
    Write-Info "Pick a region from https://docs.aws.amazon.com/global-infrastructure/latest/regions/aws-regions.html"
    $Region = (Read-Host "AWS region (e.g. us-east-1)").Trim()
}
while ([string]::IsNullOrWhiteSpace($RegionShort)) {
    Write-Info "Pick a short lowercase code for that region; it goes into resource names."
    $RegionShort = (Read-Host "Short region code (e.g. use1 for us-east-1)").Trim()
}
Write-Ok "Region: $Region (short code: $RegionShort)"

$identity = Invoke-Aws -Arguments @("sts", "get-caller-identity")
$accountId = [string]$identity.Account
$partition = ([string]$identity.Arn).Split(":")[1]
Write-Ok "AWS account $accountId ($partition), region $Region, caller $($identity.Arn)"

if (-not $SkipGitHub) {
    if ([string]::IsNullOrWhiteSpace($Repo)) {
        $Repo = (& gh repo view --json nameWithOwner -q .nameWithOwner 2>$null)
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($Repo)) {
            throw "Could not resolve the GitHub repository. Pass -Repo owner/name."
        }
        $Repo = $Repo.Trim()
    }
    Write-Ok "GitHub repository: $Repo"
} elseif ([string]::IsNullOrWhiteSpace($Repo)) {
    throw "-Repo owner/name is required with -SkipGitHub (it is the OIDC trust subject)."
}
$repoOwner, $repoName = $Repo.Split("/", 2)

$namePrefix = "$ProjectName-$Environment-$RegionShort"
$deployRoleName = "$namePrefix-github-deploy"
$bootstrapPolicyName = "$namePrefix-bootstrap-deploy-write"
$oidcProviderArn = "arn:${partition}:iam::${accountId}:oidc-provider/token.actions.githubusercontent.com"
if ([string]::IsNullOrWhiteSpace($TfstateBucket)) {
    $TfstateBucket = "$ProjectName-tfstate-$accountId-$RegionShort"
}

# ─── -RemoveBootstrapPolicy: the post-first-apply cleanup, then exit ──────────
if ($RemoveBootstrapPolicy) {
    Write-Step "Removing the inline bootstrap policy from $deployRoleName"
    $attached = Invoke-Aws -Arguments @("iam", "list-attached-role-policies", "--role-name", $deployRoleName)
    $managedPresent = @($attached.AttachedPolicies | Where-Object { $_.PolicyName -eq "$namePrefix-deploy-write" }).Count -gt 0
    if (-not $managedPresent) {
        throw "The Terraform-managed policy $namePrefix-deploy-write is not attached to $deployRoleName yet. Run the first 210 apply before removing the bootstrap copy, or CI loses its write access."
    }
    if ($PSCmdlet.ShouldProcess($deployRoleName, "delete inline policy $bootstrapPolicyName")) {
        Invoke-Aws -Arguments @("iam", "delete-role-policy", "--role-name", $deployRoleName, "--policy-name", $bootstrapPolicyName) -NoOutput | Out-Null
    }
    Write-Ok "Inline bootstrap policy removed; $deployRoleName now carries only Terraform-managed permissions."
    return
}

# ─── 1. GitHub OIDC identity provider ─────────────────────────────────────────
Write-Step "Ensuring GitHub OIDC identity provider"
$provider = Invoke-Aws -Arguments @("iam", "get-open-id-connect-provider", "--open-id-connect-provider-arn", $oidcProviderArn) -AllowFailure
if ($provider) {
    Write-Ok "Provider exists: $oidcProviderArn"
    if (-not ($provider.ClientIDList -contains "sts.amazonaws.com")) {
        if ($PSCmdlet.ShouldProcess($oidcProviderArn, "add client id sts.amazonaws.com")) {
            Invoke-Aws -Arguments @("iam", "add-client-id-to-open-id-connect-provider", "--open-id-connect-provider-arn", $oidcProviderArn, "--client-id", "sts.amazonaws.com") -NoOutput | Out-Null
        }
        Write-Ok "Added audience sts.amazonaws.com"
    }
} else {
    $thumbprint = Get-GitHubOidcRootThumbprint
    if ($PSCmdlet.ShouldProcess($oidcProviderArn, "create OIDC provider")) {
        Invoke-Aws -Arguments @(
            "iam", "create-open-id-connect-provider",
            "--url", "https://token.actions.githubusercontent.com",
            "--client-id-list", "sts.amazonaws.com",
            "--thumbprint-list", $thumbprint,
            "--tags", "Key=Name,Value=$namePrefix-github-oidc", "Key=Project,Value=$ProjectName"
        ) | Out-Null
    }
    Write-Ok "Created provider: $oidcProviderArn"
}

# ─── 2. Deploy role — trust policy identical to modules/identity ──────────────
Write-Step "Ensuring deploy role $deployRoleName"
$trustPolicy = [ordered]@{
    Version   = "2012-10-17"
    Statement = @(
        [ordered]@{
            Sid       = "GitHubOidc"
            Effect    = "Allow"
            Principal = @{ Federated = $oidcProviderArn }
            Action    = "sts:AssumeRoleWithWebIdentity"
            Condition = [ordered]@{
                StringEquals = @{ "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com" }
                StringLike   = @{ "token.actions.githubusercontent.com:sub" = "repo:${repoOwner}/${repoName}:*" }
            }
        }
    )
}
$trustFile = Write-TempJson -Document $trustPolicy
try {
    $role = Invoke-Aws -Arguments @("iam", "get-role", "--role-name", $deployRoleName) -AllowFailure
    if ($role) {
        if ($PSCmdlet.ShouldProcess($deployRoleName, "update trust policy")) {
            Invoke-Aws -Arguments @("iam", "update-assume-role-policy", "--role-name", $deployRoleName, "--policy-document", "file://$trustFile") -NoOutput | Out-Null
        }
        Write-Ok "Role exists; trust policy refreshed"
    } else {
        if ($PSCmdlet.ShouldProcess($deployRoleName, "create role")) {
            $role = Invoke-Aws -Arguments @(
                "iam", "create-role",
                "--role-name", $deployRoleName,
                "--assume-role-policy-document", "file://$trustFile",
                "--description", "GitHub Actions OIDC deploy role for $Repo ($Environment)",
                "--tags", "Key=Name,Value=$deployRoleName", "Key=Project,Value=$ProjectName", "Key=Environment,Value=$Environment"
            )
        }
        Write-Ok "Created role"
    }
} finally {
    Remove-Item -Path $trustFile -Force -ErrorAction SilentlyContinue
}
$deployRoleArn = "arn:${partition}:iam::${accountId}:role/${deployRoleName}"

# The three assessment reader policies the identity module attaches.
foreach ($policyName in @("ReadOnlyAccess", "SecurityAudit", "AWSBillingReadOnlyAccess")) {
    $policyArn = "arn:${partition}:iam::aws:policy/$policyName"
    $attached = Invoke-Aws -Arguments @("iam", "list-attached-role-policies", "--role-name", $deployRoleName)
    if (@($attached.AttachedPolicies | Where-Object { $_.PolicyArn -eq $policyArn }).Count -gt 0) {
        Write-Ok "Attached already: $policyName"
        continue
    }
    if ($PSCmdlet.ShouldProcess($deployRoleName, "attach $policyName")) {
        Invoke-Aws -Arguments @("iam", "attach-role-policy", "--role-name", $deployRoleName, "--policy-arn", $policyArn) -NoOutput | Out-Null
    }
    Write-Ok "Attached: $policyName"
}

# Inline bootstrap copy of the module's deploy-write policy. Same three
# statements, plus the services the stack also creates that the module's
# policy does not yet name (Bedrock, SNS, X-Ray) so the FIRST apply can
# succeed; TODO.md T-111 tracks tightening both to concrete ARNs once the
# account is live.
$bootstrapPolicy = [ordered]@{
    Version   = "2012-10-17"
    Statement = @(
        [ordered]@{
            Sid       = "ECSCreateTagged"
            Effect    = "Allow"
            Action    = @("ecs:CreateCluster", "ecs:CreateService", "ecs:RegisterTaskDefinition", "ecs:RunTask", "ecs:TagResource")
            Resource  = @("*")
            Condition = @{ StringEquals = @{ "aws:RequestTag/Project" = $ProjectName } }
        },
        [ordered]@{
            Sid      = "ECSRead"
            Effect   = "Allow"
            Action   = @("ecs:Describe*", "ecs:List*", "ecs:DeregisterTaskDefinition")
            Resource = @("*")
        },
        [ordered]@{
            Sid       = "ECSTagScoped"
            Effect    = "Allow"
            Action    = @("ecs:*")
            Resource  = @("*")
            Condition = @{ StringEquals = @{ "aws:ResourceTag/Project" = $ProjectName } }
        },
        [ordered]@{
            Sid      = "InfraManagement"
            Effect   = "Allow"
            Action   = @(
                "ec2:*", "elasticloadbalancing:*", "rds:*", "s3:*", "secretsmanager:*",
                "cloudfront:*", "wafv2:*", "logs:*", "iam:*", "kms:*", "cloudwatch:*",
                "application-autoscaling:*", "bedrock:*", "sns:*", "xray:*"
            )
            Resource = @("*")
        },
        [ordered]@{
            Sid      = "TerraformState"
            Effect   = "Allow"
            Action   = @(
                "s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket",
                "dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem", "dynamodb:DescribeTable",
                "dynamodb:CreateTable", "dynamodb:TagResource"
            )
            Resource = @(
                "arn:${partition}:s3:::${TfstateBucket}",
                "arn:${partition}:s3:::${TfstateBucket}/*",
                "arn:${partition}:dynamodb:${Region}:${accountId}:table/${TfstateLockTable}"
            )
        }
    )
}
$policyFile = Write-TempJson -Document $bootstrapPolicy
try {
    if ($PSCmdlet.ShouldProcess($deployRoleName, "put inline policy $bootstrapPolicyName")) {
        Invoke-Aws -Arguments @("iam", "put-role-policy", "--role-name", $deployRoleName, "--policy-name", $bootstrapPolicyName, "--policy-document", "file://$policyFile") -NoOutput | Out-Null
    }
    Write-Ok "Inline bootstrap deploy-write policy in place ($bootstrapPolicyName)"
} finally {
    Remove-Item -Path $policyFile -Force -ErrorAction SilentlyContinue
}

# ─── 3. Terraform state backend ───────────────────────────────────────────────
Write-Step "Ensuring Terraform state backend"
if (Test-AwsCall -Arguments @("s3api", "head-bucket", "--bucket", $TfstateBucket)) {
    Write-Ok "S3 bucket exists: $TfstateBucket"
} else {
    if ($PSCmdlet.ShouldProcess($TfstateBucket, "create state bucket")) {
        $createArgs = @("s3api", "create-bucket", "--bucket", $TfstateBucket, "--object-ownership", "BucketOwnerEnforced")
        # us-east-1 rejects an explicit LocationConstraint; every other region requires one.
        if ($Region -ne "us-east-1") {
            $createArgs += @("--create-bucket-configuration", "LocationConstraint=$Region")
        }
        Invoke-Aws -Arguments $createArgs | Out-Null
    }
    Write-Ok "Created S3 bucket: $TfstateBucket"
}
if ($PSCmdlet.ShouldProcess($TfstateBucket, "enforce versioning, SSE-KMS, public access block")) {
    Invoke-Aws -Arguments @("s3api", "put-bucket-versioning", "--bucket", $TfstateBucket, "--versioning-configuration", "Status=Enabled") -NoOutput | Out-Null
    $encryption = @{ Rules = @(@{ ApplyServerSideEncryptionByDefault = @{ SSEAlgorithm = "aws:kms" }; BucketKeyEnabled = $true }) }
    $encFile = Write-TempJson -Document $encryption
    try {
        Invoke-Aws -Arguments @("s3api", "put-bucket-encryption", "--bucket", $TfstateBucket, "--server-side-encryption-configuration", "file://$encFile") -NoOutput | Out-Null
    } finally {
        Remove-Item -Path $encFile -Force -ErrorAction SilentlyContinue
    }
    Invoke-Aws -Arguments @("s3api", "put-public-access-block", "--bucket", $TfstateBucket, "--public-access-block-configuration", "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true") -NoOutput | Out-Null
}
Write-Ok "Bucket hardening applied (versioning, SSE-KMS with bucket key, public access blocked)"

$table = Invoke-Aws -Arguments @("dynamodb", "describe-table", "--table-name", $TfstateLockTable) -AllowFailure
if ($table) {
    Write-Ok "DynamoDB lock table exists: $TfstateLockTable"
} else {
    if ($PSCmdlet.ShouldProcess($TfstateLockTable, "create lock table")) {
        Invoke-Aws -Arguments @(
            "dynamodb", "create-table",
            "--table-name", $TfstateLockTable,
            "--attribute-definitions", "AttributeName=LockID,AttributeType=S",
            "--key-schema", "AttributeName=LockID,KeyType=HASH",
            "--billing-mode", "PAY_PER_REQUEST",
            "--sse-specification", "Enabled=true,SSEType=KMS",
            "--tags", "Key=Project,Value=$ProjectName"
        ) | Out-Null
        Invoke-Aws -Arguments @("dynamodb", "wait", "table-exists", "--table-name", $TfstateLockTable) -NoOutput | Out-Null
    }
    Write-Ok "Created DynamoDB lock table: $TfstateLockTable"
}

# ─── 4. GitHub secrets, variables, environments ───────────────────────────────
if (-not $SkipGitHub) {
    Write-Step "Recording the backend and deploy role in GitHub ($Repo)"
    foreach ($envName in @("dev", "prod", "hub")) { Confirm-GitHubEnvironment -RepoName $Repo -Name $envName }

    Set-GitHubVariable -RepoName $Repo -Name "TFSTATE_BUCKET" -Value $TfstateBucket
    Set-GitHubVariable -RepoName $Repo -Name "TFSTATE_LOCK_TABLE" -Value $TfstateLockTable
    Set-GitHubVariable -RepoName $Repo -Name "AWS_REGION" -Value $Region
    Set-GitHubVariable -RepoName $Repo -Name "AWS_REGION_SHORT" -Value $RegionShort

    # The environment's own role for its plan/apply jobs; prod's hub approval
    # gate authenticates under the prod role too, as on Azure.
    Set-GitHubSecretValue -RepoName $Repo -Name "AWS_DEPLOY_ROLE_ARN" -Value $deployRoleArn -EnvironmentName $Environment
    if ($Environment -eq "prod") {
        Set-GitHubSecretValue -RepoName $Repo -Name "AWS_DEPLOY_ROLE_ARN" -Value $deployRoleArn -EnvironmentName "hub"
    }
    $repoSecretNames = @()
    $secretListJson = & gh secret list --repo $Repo --json name 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace(($secretListJson | Out-String))) {
        $repoSecretNames = @((($secretListJson | Out-String) | ConvertFrom-Json) | ForEach-Object { $_.name })
    }
    if ($repoSecretNames -notcontains "AWS_DEPLOY_ROLE_ARN") {
        Set-GitHubSecretValue -RepoName $Repo -Name "AWS_DEPLOY_ROLE_ARN" -Value $deployRoleArn
    } else {
        Write-Ok "Repository-level AWS_DEPLOY_ROLE_ARN already set (left as is — repo-level jobs keep their current role)"
    }
}

# ─── Hand-off ─────────────────────────────────────────────────────────────────
Write-Step "Hand the OIDC provider and role to Terraform before the first apply"
Write-Host ""
Write-Host "  The identity module declares both. Import them into the $Environment workload" -ForegroundColor White
Write-Host "  state so the first apply adopts them instead of failing on a duplicate create:" -ForegroundColor White
Write-Host ""
Write-Host "    cd infra/terraform/environments/$Environment/workload"
Write-Host "    terraform import module.identity.aws_iam_openid_connect_provider.github $oidcProviderArn"
Write-Host "    terraform import module.identity.aws_iam_role.github_deploy $deployRoleName"
Write-Host "    terraform import module.identity.aws_iam_role_policy_attachment.deploy_readonly $deployRoleName/arn:${partition}:iam::aws:policy/ReadOnlyAccess"
Write-Host "    terraform import module.identity.aws_iam_role_policy_attachment.deploy_security_audit $deployRoleName/arn:${partition}:iam::aws:policy/SecurityAudit"
Write-Host "    terraform import module.identity.aws_iam_role_policy_attachment.deploy_billing_reader $deployRoleName/arn:${partition}:iam::aws:policy/AWSBillingReadOnlyAccess"
Write-Host ""
Write-Host "  After that apply has attached $namePrefix-deploy-write, re-run this script with" -ForegroundColor White
Write-Host "  -RemoveBootstrapPolicy to drop the inline bootstrap copy." -ForegroundColor White

New-Item -ItemType Directory -Path $ReportDirectory -Force | Out-Null
$reportPath = Join-Path $ReportDirectory "$((Get-Date).ToString('yyyyMMdd-HHmmss'))-aws-$Environment.json"
[ordered]@{
    generated_at        = (Get-Date).ToUniversalTime().ToString("o")
    repository          = $Repo
    environment         = $Environment
    account_id          = $accountId
    partition           = $partition
    region              = $Region
    region_short        = $RegionShort
    oidc_provider_arn   = $oidcProviderArn
    deploy_role_arn     = $deployRoleArn
    bootstrap_policy    = $bootstrapPolicyName
    tfstate_bucket      = $TfstateBucket
    tfstate_lock_table  = $TfstateLockTable
    github_updated      = (-not $SkipGitHub)
} | ConvertTo-Json | Set-Content -Path $reportPath -Encoding UTF8
Write-Ok "Report written: $reportPath (no credential values)"
