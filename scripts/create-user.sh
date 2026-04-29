#!/usr/bin/env bash
# Create a user in both Keycloak (kiro-idp realm) and AWS IAM Identity Center,
# then add the IdC user to the kiro-group group.
#
# AWS Identity Center requires SAML NameID to be in email format, so the
# Keycloak SAML client uses saml_name_id_format = email. The NameID sent by
# Keycloak is therefore the user's email attribute. For IdC to match it,
# IdC UserName MUST equal that email.
#
#     Keycloak user.email == IdC user.UserName (both are the full email)
#
# Usage:
#   bash create-user.sh <username> <password> <email> <first> <last>
#
# All 5 arguments are required. Example:
#   bash create-user.sh alice '<strong-password>' alice@example.com alice doe
#
# Display name is auto-derived as "<last> <first>".
set -euo pipefail

# ---------- config (shared with integrate.sh) ----------
KC_URL="https://sso.example.com"
REALM="kiro-idp"
KC_REGION="eu-central-1"
KC_ADMIN_SECRET_ID="prod/kc/admin"

IDC_REGION="us-east-1"
IDENTITY_STORE_ID="d-xxxxxxxxxx"
IDC_GROUP_NAME="kiro-group"

# ---------- args ----------
if [ "$#" -ne 5 ]; then
    cat <<EOF >&2
Usage: $0 <username> <password> <email> <first_name> <last_name>

Example:
  $0 alice '<strong-password>' alice@example.com alice doe
EOF
    exit 1
fi

USERNAME="$1"
PASSWORD="$2"
EMAIL="$3"
FIRST_NAME="$4"
LAST_NAME="$5"
DISPLAY_NAME="${LAST_NAME} ${FIRST_NAME}"

echo "=== Creating user ==="
echo "  Username:     ${USERNAME}"
echo "  Email:        ${EMAIL}"
echo "  First name:   ${FIRST_NAME}"
echo "  Last name:    ${LAST_NAME}"
echo "  Display name: ${DISPLAY_NAME}"
echo ""

# ---------- fetch Keycloak admin credentials ----------
KC_ADMIN_JSON=$(aws secretsmanager get-secret-value \
    --region "${KC_REGION}" \
    --secret-id "${KC_ADMIN_SECRET_ID}" \
    --query SecretString --output text)
KC_ADMIN_USER=$(echo "${KC_ADMIN_JSON}" | python3 -c "import sys,json; print(json.load(sys.stdin)['username'])")
KC_ADMIN_PASS=$(echo "${KC_ADMIN_JSON}" | python3 -c "import sys,json; print(json.load(sys.stdin)['password'])")

# ---------- Step 1: Keycloak user ----------
echo "[Step 1] 在 Keycloak 创建用户..."

KC_TOKEN=$(curl -sf -X POST "${KC_URL}/realms/master/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "username=${KC_ADMIN_USER}" \
    --data-urlencode "password=${KC_ADMIN_PASS}" \
    --data-urlencode "grant_type=password" \
    --data-urlencode "client_id=admin-cli" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

# Check if user exists
EXISTING_KC_USER_ID=$(curl -sf -G "${KC_URL}/admin/realms/${REALM}/users" \
    -H "Authorization: Bearer ${KC_TOKEN}" \
    --data-urlencode "username=${USERNAME}" \
    --data-urlencode "exact=true" \
    | python3 -c "
import sys, json
users = json.load(sys.stdin)
print(users[0]['id'] if users else '')
")

if [ -n "${EXISTING_KC_USER_ID}" ]; then
    echo "  ⚠️ Keycloak 用户已存在: ${USERNAME} (${EXISTING_KC_USER_ID})，跳过创建"
    KC_USER_ID="${EXISTING_KC_USER_ID}"
else
    # Create user (password not included here; set separately after creation)
    USER_PAYLOAD=$(python3 -c "
import json
print(json.dumps({
    'username': '${USERNAME}',
    'enabled': True,
    'emailVerified': True,
    'email': '${EMAIL}',
    'firstName': '${FIRST_NAME}',
    'lastName': '${LAST_NAME}',
    'attributes': {'displayName': ['${DISPLAY_NAME}']}
}))
")

    HTTP_CODE=$(curl -s -o /tmp/kc-create.out -w "%{http_code}" \
        -X POST "${KC_URL}/admin/realms/${REALM}/users" \
        -H "Authorization: Bearer ${KC_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "${USER_PAYLOAD}")

    if [ "${HTTP_CODE}" != "201" ]; then
        echo "  ❌ 创建失败 (HTTP ${HTTP_CODE})"
        cat /tmp/kc-create.out
        exit 1
    fi

    KC_USER_ID=$(curl -sf -G "${KC_URL}/admin/realms/${REALM}/users" \
        -H "Authorization: Bearer ${KC_TOKEN}" \
        --data-urlencode "username=${USERNAME}" \
        --data-urlencode "exact=true" \
        | python3 -c "import sys, json; print(json.load(sys.stdin)[0]['id'])")

    echo "  ✅ Keycloak 用户已创建: ${USERNAME} (${KC_USER_ID})"
fi

# Set / reset password (non-temporary)
CRED_PAYLOAD=$(python3 -c "
import json
print(json.dumps({'type':'password','value':'${PASSWORD}','temporary':False}))
")
curl -sf -X PUT "${KC_URL}/admin/realms/${REALM}/users/${KC_USER_ID}/reset-password" \
    -H "Authorization: Bearer ${KC_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${CRED_PAYLOAD}"
echo "  ✅ 密码已设置（非临时）"

# ---------- Step 2: Identity Center user ----------
echo ""
echo "[Step 2] 在 Identity Center 创建用户..."

# IdC UserName must equal Keycloak user.email (see comment at top of file).
IC_USERNAME="${EMAIL}"

EXISTING_IC_USER_ID=$(aws identitystore list-users \
    --region "${IDC_REGION}" \
    --identity-store-id "${IDENTITY_STORE_ID}" \
    --filters "AttributePath=UserName,AttributeValue=${IC_USERNAME}" \
    --query "Users[0].UserId" --output text 2>/dev/null || true)

if [ -n "${EXISTING_IC_USER_ID}" ] && [ "${EXISTING_IC_USER_ID}" != "None" ]; then
    echo "  ⚠️ IdC 用户已存在: ${IC_USERNAME} (${EXISTING_IC_USER_ID})，跳过创建"
    IC_USER_ID="${EXISTING_IC_USER_ID}"
else
    IC_USER_ID=$(aws identitystore create-user \
        --region "${IDC_REGION}" \
        --identity-store-id "${IDENTITY_STORE_ID}" \
        --user-name "${IC_USERNAME}" \
        --display-name "${DISPLAY_NAME}" \
        --name "{\"GivenName\":\"${FIRST_NAME}\",\"FamilyName\":\"${LAST_NAME}\"}" \
        --emails "[{\"Value\":\"${EMAIL}\",\"Type\":\"work\",\"Primary\":true}]" \
        --query UserId --output text)

    echo "  ✅ IdC 用户已创建: ${IC_USERNAME} (${IC_USER_ID})"
fi

# ---------- Step 3: Add to kiro-group ----------
echo ""
echo "[Step 3] 加入 ${IDC_GROUP_NAME} 组..."

GROUP_ID=$(aws identitystore list-groups \
    --region "${IDC_REGION}" \
    --identity-store-id "${IDENTITY_STORE_ID}" \
    --filters "AttributePath=DisplayName,AttributeValue=${IDC_GROUP_NAME}" \
    --query "Groups[0].GroupId" --output text)

if [ -z "${GROUP_ID}" ] || [ "${GROUP_ID}" = "None" ]; then
    echo "  ❌ ${IDC_GROUP_NAME} 组不存在，请先在 IdC 创建该组"
    exit 1
fi

# Check if already a member
EXISTING_MEMBERSHIP=$(aws identitystore list-group-memberships-for-member \
    --region "${IDC_REGION}" \
    --identity-store-id "${IDENTITY_STORE_ID}" \
    --member-id "UserId=${IC_USER_ID}" \
    --query "GroupMemberships[?GroupId=='${GROUP_ID}'].MembershipId" \
    --output text 2>/dev/null || true)

if [ -n "${EXISTING_MEMBERSHIP}" ] && [ "${EXISTING_MEMBERSHIP}" != "None" ]; then
    echo "  ⚠️ 用户已在 ${IDC_GROUP_NAME} 组中，跳过"
else
    aws identitystore create-group-membership \
        --region "${IDC_REGION}" \
        --identity-store-id "${IDENTITY_STORE_ID}" \
        --group-id "${GROUP_ID}" \
        --member-id "UserId=${IC_USER_ID}" \
        --query MembershipId --output text > /dev/null

    echo "  ✅ 已加入 ${IDC_GROUP_NAME}"
fi

# ---------- Summary ----------
echo ""
echo "============================================================"
echo "  ✅ 完成"
echo "============================================================"
echo "  Keycloak user:  ${USERNAME} (id=${KC_USER_ID})"
echo "  IdC user:       ${USERNAME} (id=${IC_USER_ID})"
echo "  IdC group:      ${IDC_GROUP_NAME} (id=${GROUP_ID})"
echo ""
echo "  登录测试:"
echo "    1. 浏览器从 203.0.113.10 打开"
echo "       https://ssoins-xxxxxxxxxxxxxxxx.portal.us-east-1.app.aws"
echo "    2. 跳转到 Keycloak → 输入 ${USERNAME} / <密码>"
echo "    3. 回到 IdC Portal 看到已分配的 AWS 账号"
echo "============================================================"
