#!/bin/bash
set -e

###############################################################################
# Keycloak (eu-central-1 production) <-> AWS IAM Identity Center (us-east-1)
# integration script.
#
# Prerequisite: the ALB security group allows the EC2 IP running this script
# to reach https://sso.example.com.
#
# Admin credentials are read from AWS Secrets Manager - no hardcoded password.
###############################################################################

KC_URL="https://sso.example.com"
KC_LOCAL="${KC_URL}"
REALM="kiro-idp"
INSTANCE_ARN="arn:aws:sso:::instance/ssoins-xxxxxxxxxxxxxxxx"
IDENTITY_STORE_ID="d-xxxxxxxxxx"
IDC_REGION="us-east-1"
KC_REGION="eu-central-1"
KC_ADMIN_SECRET_ID="prod/kc/admin"

# Fetch admin credentials from Secrets Manager (Keycloak region)
KC_ADMIN_JSON=$(aws secretsmanager get-secret-value \
    --region "${KC_REGION}" \
    --secret-id "${KC_ADMIN_SECRET_ID}" \
    --query SecretString --output text)
KC_ADMIN_USER=$(echo "${KC_ADMIN_JSON}" | python3 -c "import sys,json; print(json.load(sys.stdin)['username'])")
KC_ADMIN_PASS=$(echo "${KC_ADMIN_JSON}" | python3 -c "import sys,json; print(json.load(sys.stdin)['password'])")

echo "=== Keycloak <-> Identity Center 集成 ==="
echo ""

###############################################################################
# Step 1: 读取 AWS 控制台拿到的信息
###############################################################################

if [ -z "$1" ] || [ -z "$2" ]; then
    echo "用法: bash integrate.sh <ACS_URL> <ISSUER_URL>"
    echo ""
    echo "  ACS_URL:    AWS 控制台 → Identity Center → Settings → Identity source"
    echo "              → \"IAM Identity Center Assertion Consumer Service (ACS) URL\""
    echo "              格式: https://d-xxxxxxxxxx.awsapps.com/saml/acs/xxxxxxxx"
    echo ""
    echo "  ISSUER_URL: AWS 控制台 → Identity Center → Settings → Identity source"
    echo "              → \"IAM Identity Center issuer URL\""
    echo "              格式: https://d-xxxxxxxxxx.awsapps.com/saml/metadata/xxxxxxxx"
    echo ""
    exit 1
fi

ACS_URL="$1"
ISSUER_URL="$2"

echo "ACS URL:    ${ACS_URL}"
echo "Issuer URL: ${ISSUER_URL}"
echo ""

###############################################################################
# Step 2: 在 Keycloak 中配置 SAML Client
###############################################################################
echo "[Step 1] 配置 Keycloak SAML Client..."

KC_TOKEN=$(curl -sf -X POST "${KC_LOCAL}/realms/master/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "username=${KC_ADMIN_USER}" \
    --data-urlencode "password=${KC_ADMIN_PASS}" \
    --data-urlencode "grant_type=password" \
    --data-urlencode "client_id=admin-cli" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

# Delete the old placeholder client
OLD_CLIENT_UUID=$(curl -sf "${KC_LOCAL}/admin/realms/${REALM}/clients" \
    -H "Authorization: Bearer ${KC_TOKEN}" | python3 -c "
import sys, json
for c in json.load(sys.stdin):
    if c['clientId'] == 'aws-identity-center':
        print(c['id']); break
" 2>/dev/null || true)

if [ -n "$OLD_CLIENT_UUID" ]; then
    curl -sf -X DELETE "${KC_LOCAL}/admin/realms/${REALM}/clients/${OLD_CLIENT_UUID}" \
        -H "Authorization: Bearer ${KC_TOKEN}"
    echo "  旧 client 已删除"
fi

# Create new SAML client with correct AWS settings
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${KC_LOCAL}/admin/realms/${REALM}/clients" \
    -H "Authorization: Bearer ${KC_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
        \"clientId\": \"${ISSUER_URL}\",
        \"name\": \"AWS IAM Identity Center\",
        \"description\": \"SAML IdP for AWS IAM Identity Center\",
        \"enabled\": true,
        \"protocol\": \"saml\",
        \"frontchannelLogout\": true,
        \"attributes\": {
            \"saml.authnstatement\": \"true\",
            \"saml.server.signature\": \"true\",
            \"saml_name_id_format\": \"urn:oasis:names:tc:SAML:2.0:nameid-format:emailAddress\",
            \"saml_force_name_id_format\": \"false\",
            \"saml.force.post.binding\": \"true\",
            \"saml.signature.algorithm\": \"RSA_SHA256\",
            \"saml_single_logout_service_url_post\": \"${ACS_URL}\",
            \"saml_assertion_consumer_url_post\": \"${ACS_URL}\",
            \"saml.signing.certificate\": \"\",
            \"saml.server.signature.keyinfo.ext\": \"false\",
            \"saml.assertion.signature\": \"true\",
            \"saml.client.signature\": \"false\"
        },
        \"redirectUris\": [\"${ACS_URL}\"],
        \"adminUrl\": \"${ACS_URL}\",
        \"fullScopeAllowed\": true
    }")

if [ "$HTTP_CODE" = "201" ]; then
    echo "  ✅ SAML Client 已创建 (clientId = Issuer URL)"
else
    echo "  ❌ 创建失败 (HTTP ${HTTP_CODE})，可能已存在"
fi

# Get the new client UUID for adding mappers
NEW_CLIENT_UUID=$(curl -sf "${KC_LOCAL}/admin/realms/${REALM}/clients" \
    -H "Authorization: Bearer ${KC_TOKEN}" | python3 -c "
import sys, json
issuer = '${ISSUER_URL}'
for c in json.load(sys.stdin):
    if c['clientId'] == issuer:
        print(c['id']); break
")

# Protocol mappers — MUST be created, otherwise Keycloak cannot populate the
# SAML <NameID> / assertion attributes and Kiro's device flow fails with
# "Invalid redirect uri" (浏览器 SP-initiated 会因为 fallback 勉强跑通，但
# Kiro OIDC device flow 更严格，所以必须显式建 mapper)。
echo "  Adding SAML attribute mappers..."

# email -> attribute "email"
curl -sf -X POST "${KC_LOCAL}/admin/realms/${REALM}/clients/${NEW_CLIENT_UUID}/protocol-mappers/models" \
    -H "Authorization: Bearer ${KC_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{
        "name": "email",
        "protocol": "saml",
        "protocolMapper": "saml-user-property-mapper",
        "config": {
            "user.attribute": "email",
            "friendly.name": "email",
            "attribute.name": "email",
            "attribute.nameformat": "URI"
        }
    }' >/dev/null 2>&1 && echo "    ✅ email mapper" || echo "    ⚠️ email mapper 已存在或失败"

# email -> Subject NameID (via urn:oid standard email OID)
curl -sf -X POST "${KC_LOCAL}/admin/realms/${REALM}/clients/${NEW_CLIENT_UUID}/protocol-mappers/models" \
    -H "Authorization: Bearer ${KC_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{
        "name": "email-nameid",
        "protocol": "saml",
        "protocolMapper": "saml-user-property-mapper",
        "config": {
            "user.attribute": "email",
            "friendly.name": "email",
            "attribute.name": "urn:oid:0.9.2342.19200300.100.1.3",
            "attribute.nameformat": "URI"
        }
    }' >/dev/null 2>&1 && echo "    ✅ email-nameid mapper" || echo "    ⚠️ email-nameid mapper 已存在或失败"

###############################################################################
# (User sync skipped on purpose: users are created manually in Keycloak and
#  Identity Center. See README for guidance.)
###############################################################################

###############################################################################
# Step 3: 验证
###############################################################################
echo ""
echo "============================================================"
echo "  ✅ 集成配置完成"
echo "============================================================"
echo ""
echo "  Identity Center Portal: https://ssoins-xxxxxxxxxxxxxxxx.portal.us-east-1.app.aws"
echo "  Keycloak:               ${KC_URL}"
echo "  Keycloak Admin:         ${KC_URL}/admin (credentials in Secrets Manager: ${KC_ADMIN_SECRET_ID})"
echo ""
echo "  测试:"
echo "    1. 浏览器打开 https://ssoins-xxxxxxxxxxxxxxxx.portal.us-east-1.app.aws"
echo "    2. 应跳转到 Keycloak 登录页 (${KC_URL})"
echo "    3. 用 Keycloak 里的用户登录（注意：必须从白名单 IP 访问）"
echo "    4. 如果 IP 在白名单内 → 回到 Identity Center 拿到 AWS 凭证"
echo ""
echo "  Kiro 测试:"
echo "    kiro-cli login --license pro \\"
echo "      --identity-provider https://${IDENTITY_STORE_ID}.awsapps.com/start \\"
echo "      --region ${IDC_REGION}"
echo ""
echo "  IP 白名单更新:"
echo "    通过 Keycloak Admin Console 的 Authentication Flow 里的 IP Check 修改"
echo "    或 (see standalone-keycloak-us-east-1/update-ip-whitelist.sh for reference)"
echo ""
echo "============================================================"
