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
     with the SAME environment-scoped trust policy the identity module declares
     (dev environment for dev; protected hub environment for prod) and an INLINE
     bootstrap deploy-write policy that mirrors the module's managed policy so
     the first Terraform apply can run.
     Terraform ignores inline policies it does not declare, so the two never
     fight; once the module's managed policy is attached by that first apply,
     re-run with -RemoveBootstrapPolicy to drop the inline copy.
  3. The selected environment's isolated Terraform state backend: a
     repository-, account-, region- and environment-specific versioned,
     SSE-KMS, public-access-blocked S3 bucket and DynamoDB lock table.
  4. The GitHub side: the dev / prod / hub environments, an environment-scoped
     AWS_DEPLOY_ROLE_ARN secret, AWS_TARGET_ACCOUNT_ID environment variable,
     and environment-scoped TFSTATE_BUCKET, TFSTATE_LOCK_TABLE, AWS_REGION
     and AWS_REGION_SHORT variables (prod uses the protected hub environment).

The OIDC provider and the deploy role are ALSO declared by
infra/terraform/modules/identity. Creating them here first is what lets CI
authenticate at all; the script prints the `terraform import` commands that
hand them to Terraform so the first apply adopts rather than duplicates them.

Secrets policy: this script never reads, prints or stores a credential value.
Cloud access is the operator's `aws` CLI session; GitHub access is `gh`. The
cloud-agnostic secrets the README lists (Docker Hub, the Entra sign-in app,
the runtime secrets of R-008) are entered separately — they are not AWS-side.

.PARAMETER Repo
Required GitHub deployment repository in owner/name form.

.PARAMETER Environment
Which environment's deploy role and isolated state backend to create: dev or
prod. Run once per environment using credentials for that exact account.

.PARAMETER ExpectedAccountId
Exact 12-digit AWS account ID expected from the active AWS CLI identity.

.PARAMETER OtherEnvironmentAccountId
Required AWS account ID for the other environment. Dev and prod must use
distinct accounts; the value is registered as a repository variable.

.PARAMETER OtherEnvironmentLockTable
Required DynamoDB lock table for the other environment. Dev and prod must use
distinct lock tables; the value is registered as a repository variable.

.PARAMETER ProjectName
Terraform var.project_name; first segment of every resource name.

.PARAMETER Region
AWS region for the state backend and the environment (Terraform var.region).

.PARAMETER RegionShort
Short region code used in resource names (Terraform var.region_short).

.PARAMETER TfstateBucket
S3 bucket for Terraform state. Globally unique; defaults to
<project>-<environment>-tfstate-<account-id>-<region_short>-<repository-hash>.

.PARAMETER TfstateLockTable
DynamoDB table for state locking. Defaults to the same project/environment/
account/region/repository-specific name as the state bucket.

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
./scripts/Initialize-CnaAwsGitHubSecrets.ps1 -Repo <owner>/<deployment-repo> -Environment dev -ExpectedAccountId <dev-12-digit-account-id> -OtherEnvironmentAccountId <prod-12-digit-account-id> -OtherEnvironmentLockTable <prod-lock-table> -Region <aws-region> -RegionShort <region-short>

.EXAMPLE
./scripts/Initialize-CnaAwsGitHubSecrets.ps1 -Repo <owner>/<deployment-repo> -Environment prod -ExpectedAccountId <prod-12-digit-account-id> -OtherEnvironmentAccountId <dev-12-digit-account-id> -OtherEnvironmentLockTable <dev-lock-table> -Region <aws-region> -RegionShort <region-short> -AwsProfile client-prod -WhatIf

.EXAMPLE
# After the first 210 apply has attached the Terraform-managed deploy-write policy:
./scripts/Initialize-CnaAwsGitHubSecrets.ps1 -Repo <owner>/<deployment-repo> -Environment dev -ExpectedAccountId <12-digit-account-id> -Region <aws-region> -RegionShort <region-short> -RemoveBootstrapPolicy
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$Repo,

    [Parameter(Mandatory = $true)]
    [ValidateSet("dev", "prod")]
    [string]$Environment,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9]{12}$')]
    [string]$ExpectedAccountId,

    [string]$OtherEnvironmentAccountId = "",

    [string]$OtherEnvironmentLockTable = "",

    [string]$ProjectName = "cna",

    # Your AWS region. No default on purpose; pass the exact target region.
    # AWS Regions: https://docs.aws.amazon.com/global-infrastructure/latest/regions/aws-regions.html
    [Parameter(Mandatory = $true)]
    [string]$Region,

    # Short lowercase code for your region (e.g. use1 for us-east-1), used in
    # resource names. No default on purpose.
    [Parameter(Mandatory = $true)]
    [string]$RegionShort,

    [string]$TfstateBucket = "",

    [string]$TfstateLockTable = "",

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

function Get-RegisteredRepositoryVariable {
    param([string]$RepoName, [string]$VariableName)
    $query = ".variables[] | select(.name == `"$VariableName`") | .value"
    $values = @(Invoke-Gh -Arguments @(
        "api", "--paginate", "repos/$RepoName/actions/variables", "--jq", $query
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($values.Count -gt 1) { throw "Multiple repository variables named $VariableName were returned." }
    if ($values.Count -eq 0) { return "" }
    return [string]$values[0]
}

function Set-GitHubVariable {
    param([string]$RepoName, [string]$Name, [string]$Value, [string]$EnvironmentName = "")
    $target = if ($EnvironmentName) { "$RepoName environment $EnvironmentName variable $Name" } else { "$RepoName variable $Name" }
    if ($PSCmdlet.ShouldProcess($target, "set")) {
        $arguments = @("variable", "set", $Name, "--repo", $RepoName, "--body", $Value)
        if ($EnvironmentName) { $arguments += @("--env", $EnvironmentName) }
        Invoke-Gh -Arguments $arguments | Out-Null
    }
    Write-Ok "Variable $Name set ($(if ($EnvironmentName) { "environment $EnvironmentName" } else { 'repository' }))"
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

# Region is explicit. Normalize and validate before any AWS call or resource
# mutation, so a malformed target fails before the script can create anything.
#   region       : lowercase letters, digits, hyphens (e.g. us-east-1)
#   region_short : ^[a-z0-9]{2,8}$ (e.g. use1)  -- mirrors variables.tf
Write-Step "Choosing your AWS region"
$Region = $Region.Trim().ToLowerInvariant()
if ($Region -notmatch '^[a-z0-9]+(-[a-z0-9]+)+-[0-9]+$') {
    throw "-Region must be a valid AWS region identifier (for example, us-east-1)."
}
$RegionShort = $RegionShort.Trim().ToLowerInvariant()
if ($RegionShort -notmatch '^[a-z0-9]{2,8}$') {
    throw "-RegionShort must be 2-8 lowercase letters or digits, for example use1."
}
Write-Ok "Region: $Region (short code: $RegionShort)"

$identity = Invoke-Aws -Arguments @("sts", "get-caller-identity")
$accountId = [string]$identity.Account
$partition = ([string]$identity.Arn).Split(":")[1]
Write-Ok "AWS account $accountId ($partition), region $Region, caller $($identity.Arn)"
if ($accountId -ne $ExpectedAccountId) {
    throw "Authenticated to AWS account $accountId, but -ExpectedAccountId is $ExpectedAccountId. No resources were changed."
}

if (-not $SkipGitHub) {
    if ([string]::IsNullOrWhiteSpace($Repo) -or $Repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
        throw "-Repo must explicitly name the GitHub deployment repository in owner/name form."
    }
    Write-Ok "GitHub repository: $Repo"
} elseif ([string]::IsNullOrWhiteSpace($Repo)) {
    throw "-Repo owner/name is required with -SkipGitHub (it is the OIDC trust subject)."
}
if ($Repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
    throw "-Repo must name the GitHub deployment repository in owner/name form."
}
$repoOwner, $repoName = $Repo.Split("/", 2)

$otherEnvironment = if ($Environment -eq "dev") { "prod" } else { "dev" }
if ($SkipGitHub) {
    if ($OtherEnvironmentAccountId -notmatch '^[0-9]{12}$' -or
        $OtherEnvironmentLockTable -notmatch '^[A-Za-z0-9_.-]{3,255}$') {
        throw "-SkipGitHub requires valid -OtherEnvironmentAccountId and -OtherEnvironmentLockTable values to enforce environment isolation."
    }
} else {
    if ([string]::IsNullOrWhiteSpace($OtherEnvironmentAccountId)) {
        $OtherEnvironmentAccountId = Get-RegisteredRepositoryVariable -RepoName $Repo -VariableName "CNA_AWS_TARGET_ACCOUNT_ID_$($otherEnvironment.ToUpperInvariant())"
    }
}
if ($OtherEnvironmentAccountId -notmatch '^[0-9]{12}$') {
    throw "Provide -OtherEnvironmentAccountId as the other environment's exact 12-digit AWS account ID before creating resources."
}
if ($accountId -eq $OtherEnvironmentAccountId) {
    throw "Dev and prod must use distinct AWS accounts. Refusing to configure $Environment in account $accountId."
}

$repoHash = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($Repo.ToLowerInvariant()))).Substring(0, 8).ToLowerInvariant()

$namePrefix = "$ProjectName-$Environment-$RegionShort"
$deployRoleName = "$namePrefix-github-deploy"
$bootstrapPolicyName = "$namePrefix-bootstrap-deploy-write"
$oidcProviderArn = "arn:${partition}:iam::${accountId}:oidc-provider/token.actions.githubusercontent.com"
if ([string]::IsNullOrWhiteSpace($TfstateBucket)) {
    $TfstateBucket = "$ProjectName-$Environment-tfstate-$accountId-$RegionShort-$repoHash"
}
if ([string]::IsNullOrWhiteSpace($TfstateLockTable)) {
    $TfstateLockTable = "$ProjectName-$Environment-tfstate-$accountId-$RegionShort-$repoHash"
}
if ($TfstateBucket -notmatch '^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$') {
    throw "TfstateBucket must be a valid 3-63 character S3 bucket name; use an explicit customer-unique name if the generated default is unavailable."
}
if ($TfstateLockTable -notmatch '^[A-Za-z0-9_.-]{3,255}$') {
    throw "TfstateLockTable must be a 3-255 character DynamoDB table name using letters, digits, '.', '_' or '-'."
}
$otherLockTableVariable = "CNA_TFSTATE_LOCK_TABLE_$($otherEnvironment.ToUpperInvariant())"
if (-not $SkipGitHub) {
    if ([string]::IsNullOrWhiteSpace($OtherEnvironmentLockTable)) {
        $OtherEnvironmentLockTable = Get-RegisteredRepositoryVariable -RepoName $Repo -VariableName $otherLockTableVariable
    }
}
if ($OtherEnvironmentLockTable -notmatch '^[A-Za-z0-9_.-]{3,255}$') {
    throw "Provide -OtherEnvironmentLockTable as the other environment's lock-table name before creating resources."
}
if ($TfstateLockTable -eq $OtherEnvironmentLockTable) {
    throw "Dev and prod must use distinct Terraform lock tables. Refusing to configure $Environment with shared table $TfstateLockTable."
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
                StringEquals = @{
                    "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
                    "token.actions.githubusercontent.com:sub" = $(if ($Environment -eq "prod") {
                        "repo:${repoOwner}/${repoName}:environment:hub"
                    } else {
                        "repo:${repoOwner}/${repoName}:environment:dev"
                    })
                }
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
$environmentTagValues = if ($Environment -eq "prod") { @("Prod", "prod") } else { @("Dev", "dev") }

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
                "ec2:*", "elasticloadbalancing:*", "rds:*", "secretsmanager:*",
                "cloudfront:*", "wafv2:*", "logs:*", "iam:*", "kms:*", "cloudwatch:*",
                "application-autoscaling:*", "bedrock:*", "sns:*", "xray:*", "tag:GetResources"
            )
            Resource = @("*")
        },
        [ordered]@{
            Sid      = "DeploymentBuckets"
            Effect   = "Allow"
            Action   = @("s3:*")
            Resource = @(
                "arn:${partition}:s3:::${ProjectName}-${Environment}-${RegionShort}-artifacts-*",
                "arn:${partition}:s3:::${ProjectName}-${Environment}-${RegionShort}-artifacts-*/*",
                "arn:${partition}:s3:::${ProjectName}-${Environment}-${RegionShort}-static-*",
                "arn:${partition}:s3:::${ProjectName}-${Environment}-${RegionShort}-static-*/*",
                "arn:${partition}:s3:::${ProjectName}-${Environment}-${RegionShort}-logs-*",
                "arn:${partition}:s3:::${ProjectName}-${Environment}-${RegionShort}-logs-*/*"
            )
        },
        [ordered]@{
            Sid      = "StateBucketAdministration"
            Effect   = "Allow"
            Action   = @("s3:CreateBucket", "s3:GetBucketLocation", "s3:PutBucketVersioning", "s3:PutEncryptionConfiguration", "s3:PutPublicAccessBlock")
            Resource = @("arn:${partition}:s3:::${TfstateBucket}")
        },
        [ordered]@{
            Sid      = "ListEnvironmentState"
            Effect   = "Allow"
            Action   = @("s3:ListBucket", "s3:ListBucketVersions")
            # The bucket is isolated per client/environment; no prefix
            # condition so backend HeadBucket probes are not denied.
            Resource = @("arn:${partition}:s3:::${TfstateBucket}")
        },
        [ordered]@{
            Sid      = "ReadWriteEnvironmentState"
            Effect   = "Allow"
            Action   = @("s3:GetObject", "s3:GetObjectVersion", "s3:PutObject", "s3:DeleteObject", "s3:DeleteObjectVersion")
            Resource = @("arn:${partition}:s3:::${TfstateBucket}/${Environment}/*")
        },
        [ordered]@{
            Sid      = "LockTableAdministration"
            Effect   = "Allow"
            Action   = @("dynamodb:DescribeTable", "dynamodb:CreateTable", "dynamodb:TagResource")
            Resource = @("arn:${partition}:dynamodb:${Region}:${accountId}:table/${TfstateLockTable}")
        },
        [ordered]@{
            Sid      = "EnvironmentStateLockItems"
            Effect   = "Allow"
            Action   = @("dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem")
            Resource = @("arn:${partition}:dynamodb:${Region}:${accountId}:table/${TfstateLockTable}")
            Condition = @{ "ForAllValues:StringLike" = @{ "dynamodb:LeadingKeys" = @("${TfstateBucket}/${Environment}/*") } }
        },
        [ordered]@{
            Sid      = "DeleteEnvironmentStateBackend"
            Effect   = "Allow"
            Action   = @("s3:DeleteBucket", "s3:DeleteObject", "s3:DeleteObjectVersion", "dynamodb:DeleteTable")
            Resource = @(
                "arn:${partition}:s3:::${TfstateBucket}",
                "arn:${partition}:s3:::${TfstateBucket}/${Environment}/*",
                "arn:${partition}:dynamodb:${Region}:${accountId}:table/${TfstateLockTable}"
            )
            Condition = @{ StringEquals = @{ "aws:PrincipalTag/Environment" = $environmentTagValues } }
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

    # All production AWS jobs use hub so its required-reviewer rule protects
    # plan, apply, teardown and drift access. Never create a repository fallback.
    $roleEnvironment = if ($Environment -eq "prod") { "hub" } else { "dev" }
    Set-GitHubSecretValue -RepoName $Repo -Name "AWS_DEPLOY_ROLE_ARN" -Value $deployRoleArn -EnvironmentName $roleEnvironment
    Set-GitHubVariable -RepoName $Repo -Name "AWS_TARGET_ACCOUNT_ID" -Value $accountId -EnvironmentName $roleEnvironment
    Set-GitHubVariable -RepoName $Repo -Name "CNA_AWS_TARGET_ACCOUNT_ID_$($Environment.ToUpperInvariant())" -Value $accountId
    Set-GitHubVariable -RepoName $Repo -Name "CNA_AWS_TARGET_ACCOUNT_ID_$($otherEnvironment.ToUpperInvariant())" -Value $OtherEnvironmentAccountId
    Set-GitHubVariable -RepoName $Repo -Name "TFSTATE_BUCKET" -Value $TfstateBucket -EnvironmentName $roleEnvironment
    Set-GitHubVariable -RepoName $Repo -Name "TFSTATE_LOCK_TABLE" -Value $TfstateLockTable -EnvironmentName $roleEnvironment
    Set-GitHubVariable -RepoName $Repo -Name "CNA_TFSTATE_LOCK_TABLE_$($Environment.ToUpperInvariant())" -Value $TfstateLockTable
    Set-GitHubVariable -RepoName $Repo -Name $otherLockTableVariable -Value $OtherEnvironmentLockTable
    Set-GitHubVariable -RepoName $Repo -Name "AWS_REGION" -Value $Region -EnvironmentName $roleEnvironment
    Set-GitHubVariable -RepoName $Repo -Name "AWS_REGION_SHORT" -Value $RegionShort -EnvironmentName $roleEnvironment
    Write-Warn "Configure required reviewers and deployment-branch restrictions on the GitHub hub environment manually before any production workflow."
}

# ─── Hand-off ─────────────────────────────────────────────────────────────────
Write-Step "Hand the OIDC provider and role to Terraform before the first apply"
Write-Host ""
Write-Host "  The identity module declares both. Import them into the $Environment workload" -ForegroundColor White
Write-Host "  state so the first apply adopts them instead of failing on a duplicate create:" -ForegroundColor White
Write-Host ""
Write-Host "    cd infra/terraform/environments/$Environment/workload"
Write-Host "    terraform init -backend-config=`"bucket=$TfstateBucket`" -backend-config=`"dynamodb_table=$TfstateLockTable`" -backend-config=`"region=$Region`" -backend-config=`"encrypt=true`" -backend-config=`"key=$Environment/workload.tfstate`""
Write-Host "    terraform import module.identity.aws_iam_openid_connect_provider.github $oidcProviderArn"
Write-Host "    terraform import module.identity.aws_iam_role.github_deploy $deployRoleName"
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
