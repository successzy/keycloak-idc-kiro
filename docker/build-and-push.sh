#!/usr/bin/env bash
# Build the custom Keycloak image and push it to ECR.
#
# Usage:
#   bash build-and-push.sh v1.0.0
#   bash build-and-push.sh v1.0.0 staging
#
# The script:
#   - Reads ECR repo URI from the kc-ecr-${ENV} CloudFormation stack output
#   - Logs in to ECR
#   - Builds a linux/amd64 image (override with PLATFORM env var)
#   - Pushes only the versioned tag (ECR repo is IMMUTABLE; no `latest`).
set -euo pipefail

TAG="${1:-}"
ENV="${2:-prod}"
REGION="${AWS_REGION:-eu-central-1}"
PLATFORM="${PLATFORM:-linux/amd64}"

if [[ -z "$TAG" ]]; then
  echo "Usage: $0 <version-tag> [environment]" >&2
  echo "Example: $0 v1.0.0 prod" >&2
  exit 1
fi

if [[ ! "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+ ]]; then
  echo "Warning: tag '${TAG}' does not look like semver (vMAJOR.MINOR.PATCH)" >&2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo ">> Resolving ECR repo URI from CloudFormation stack kc-ecr-${ENV}..."
REPO_URI=$(aws cloudformation describe-stacks \
  --region "$REGION" \
  --stack-name "kc-ecr-${ENV}" \
  --query "Stacks[0].Outputs[?OutputKey=='RepositoryUri'].OutputValue" \
  --output text)

if [[ -z "$REPO_URI" || "$REPO_URI" == "None" ]]; then
  echo "ERROR: could not read RepositoryUri from stack kc-ecr-${ENV}" >&2
  exit 1
fi
echo "   Repo: ${REPO_URI}"

IMAGE_URI="${REPO_URI}:${TAG}"

REGISTRY="${REPO_URI%%/*}"
echo ">> Logging in to ${REGISTRY}..."
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY"

echo ">> Building image ${IMAGE_URI} for ${PLATFORM}..."
docker build \
  --platform "$PLATFORM" \
  --tag "$IMAGE_URI" \
  --build-arg KEYCLOAK_VERSION="${KEYCLOAK_VERSION:-26.2.4}" \
  .

echo ">> Pushing ${IMAGE_URI}..."
docker push "$IMAGE_URI"

echo ""
echo "Pushed successfully:"
echo "  ${IMAGE_URI}"
echo ""
echo "Next steps:"
echo "  - Record this tag in your ECS task definition parameter (e.g. ImageTag=${TAG})."
echo "  - Roll the ECS service with: aws ecs update-service --force-new-deployment ..."
