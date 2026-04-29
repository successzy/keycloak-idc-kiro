# keycloak-idc-kiro

Infrastructure-as-code and helper scripts for running Keycloak on Amazon ECS
Fargate as an external SAML Identity Provider for AWS IAM Identity Center.

## Directory layout

| Path | Contents |
|---|---|
| [`cfn/`](cfn/) | Five CloudFormation stacks. Deploy in numeric order — each stack imports exports from the previous one. |
| [`docker/`](docker/) | Two-stage `Dockerfile` for the custom Keycloak image, plus a build-and-push helper for ECR. |
| [`scripts/`](scripts/) | Bash utilities that call the Keycloak Admin API and AWS IdC SDK to finish the SAML integration after the infrastructure is up. |
| [`images/`](images/) | Architecture diagram source (`architecture.drawio`) and login-flow screenshots. |

### `cfn/`

| File | Purpose |
|---|---|
| `01-network.yaml` | VPC across 3 AZs, public/app/db subnets, single NAT Gateway, security groups, interface + gateway VPC endpoints. |
| `02-database.yaml` | KMS CMK, Secrets Manager entry for DB credentials, Aurora PostgreSQL 15 cluster with a single `db.t4g.medium` writer. |
| `03-ecr.yaml` | Private ECR repository with `ImageTagMutability: IMMUTABLE`, scan-on-push, and a lifecycle policy. |
| `04-alb-dns.yaml` | ACM certificate (DNS-validated), public Application Load Balancer, IP-mode Target Group, HTTPS listener, Route53 A-alias. |
| `05-ecs.yaml` | ECS Fargate cluster, task definition, service, CloudWatch log group, IAM roles, CPU target-tracking auto scaling. |

### `docker/`

| File | Purpose |
|---|---|
| `Dockerfile` | Builder stage runs `kc.sh build` to compile Keycloak with the chosen options; runtime stage copies the optimized distribution. |
| `.dockerignore` | Keeps the build context small. |
| `build-and-push.sh` | Reads the ECR URI from CloudFormation stack outputs, logs in, builds for `linux/amd64`, and pushes a versioned tag. |
| `themes/` | Placeholder for custom Keycloak themes. |

### `scripts/`

All three scripts read the Keycloak admin credentials from AWS Secrets Manager
and are idempotent — they can be re-run safely.

| File | Purpose |
|---|---|
| `integrate.sh` | Creates (or recreates) the AWS IAM Identity Center SAML Client in Keycloak, including the two `saml-user-property-mapper` protocol mappers that put the user's email into the SAML NameID. |
| `create-user.sh` | Provisions a user in both Keycloak and the IdC Identity Store in one shot, and adds the IdC user to the `kiro-group` group. |
| `configure-ip-flow.sh` | Clones the built-in `browser` flow to `ip-restricted-browser`, adds the custom IP-check authenticator execution inside the forms sub-flow, writes the allowed-IP list, and binds the flow as the realm's `browserFlow`. |

## Placeholders

Files in this repository use placeholder values in place of a real deployment
(for example `example.com` for the Keycloak hostname and `d-xxxxxxxxxx` for the
IdC Identity Store ID). Substitute your own values before deploying.
