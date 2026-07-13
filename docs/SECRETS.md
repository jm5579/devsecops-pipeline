# GitHub Actions Secrets Configuration

This project stores every credential the pipeline needs as an encrypted
**GitHub Actions secret**, scoped to the repository (or, in production,
to the `production` **environment** so a required-reviewer gate can be
added in repo settings). No credential ever appears in a workflow file,
a Terraform file, or application source.

## 1. Repository secrets to create

Go to **Settings > Secrets and variables > Actions > New repository
secret** and add each of the following:

| Secret name | Value | Used by |
|---|---|---|
| `SNYK_TOKEN` | Your Snyk API token (Snyk dashboard > Account Settings > API Token) | `snyk-dependency-scan` job |
| `AWS_DEPLOY_ROLE_ARN` | The `github_actions_deploy_role_arn` Terraform output | `deploy` job (OIDC role assumption) |
| `CI_TEST_FLASK_SECRET_KEY` | A throwaway random string, e.g. `openssl rand -hex 32` | `zap-dast-scan` job, for the ephemeral CI container only |

**There is no AWS access key ID / secret access key secret.** Production
AWS access is granted via OpenID Connect federation
(`aws-actions/configure-aws-credentials@v4` with `role-to-assume`), so
GitHub issues a short-lived, per-run credential instead of using a
long-lived static key. This removes an entire class of risk: a leaked
GitHub secret can no longer hand out a permanent AWS credential.

## 2. Why OIDC instead of static AWS keys

1. In `terraform/modules/iam/main.tf`, the `aws_iam_openid_connect_provider`
   resource registers GitHub's OIDC issuer with your AWS account (do this
   once per account).
2. The `github_actions_deploy` IAM role's trust policy restricts
   `sts:AssumeRoleWithWebIdentity` to tokens whose `sub` claim matches
   `repo:<your-org>/<your-repo>:ref:refs/heads/main` - so only a workflow
   run triggered by a push to `main` on this exact repository can assume
   the role. A fork, a feature branch, or a different repository cannot.
3. After `terraform apply`, copy the `github_actions_deploy_role_arn`
   output into the `AWS_DEPLOY_ROLE_ARN` secret above.

## 3. Flask application secret key flow

`FLASK_SECRET_KEY` is never a GitHub secret used at deploy time - it is
provisioned entirely inside AWS so it never has to leave AWS:

1. `terraform apply` creates an SSM Parameter Store `SecureString` named
   `/secure-python-app/flask-secret-key` with a placeholder value.
2. Immediately after the first apply, a human with appropriate AWS
   access overwrites the real value once, out-of-band:
   ```bash
   aws ssm put-parameter \
     --name "/secure-python-app/flask-secret-key" \
     --value "$(openssl rand -hex 32)" \
     --type SecureString \
     --overwrite \
     --region ca-central-1
   ```
3. The EC2 instance's `systemd` unit (see
   `terraform/modules/ec2/user_data.sh.tftpl`) fetches and decrypts that
   parameter at service start time using its own IAM role - the value
   never transits GitHub Actions, never appears in a workflow log, and
   never appears in Terraform state (the resource's `value` is a
   deliberate placeholder with `lifecycle { ignore_changes = [value] }`).

## 4. Rotating a secret

- **Snyk token / CI test secret**: update the GitHub secret value; no
  further action needed, the next workflow run picks it up.
- **AWS deploy role**: re-running `terraform apply` after any trust
  policy change updates the role in place; the ARN itself doesn't change
  unless the role is destroyed and recreated.
- **Flask secret key**: run the `aws ssm put-parameter --overwrite`
  command above with a new value, then restart the service
  (`aws ssm send-command ... systemctl restart secure-python-app.service`).

## 5. What CI never has access to

- No SSH private key exists anywhere in this project - see
  `terraform/modules/ec2/main.tf` (`key_name` is intentionally omitted).
- No static, long-lived AWS credential is stored as a GitHub secret.
- No secret is ever printed in a workflow log; the `zap-dast-scan` job's
  test key is injected via `env:` from a GitHub secret, never echoed.
