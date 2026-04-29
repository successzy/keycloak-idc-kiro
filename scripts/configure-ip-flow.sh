#!/usr/bin/env bash
# Configure IP whitelist authentication flow on the production Keycloak
# (eu-central-1, sso.example.com, realm kiro-idp).
#
# What this does (idempotent):
#   1. Verify custom SPI "ip-check-authenticator" is registered
#   2. Create authentication flow "ip-restricted-browser" by cloning the
#      built-in "browser" flow (skip if exists)
#   3. Add an "IP Address Check" execution INSIDE the "... forms" sub-flow
#      (level 1), next to "Username Password Form" — both REQUIRED.
#      This is critical: putting IP Check at level 0 breaks the login form
#      (Keycloak ignores ALTERNATIVE executions when a sibling is REQUIRED).
#      See standalone-keycloak-us-east-1/demo-INTEGRATION-GUIDE.md 坑 #2.
#   4. Create/update its config with `allowed_ips`
#   5. Bind the realm's browserFlow to "ip-restricted-browser"
#
# Usage:
#   bash configure-ip-flow.sh                      # use default whitelist
#   bash configure-ip-flow.sh "1.2.3.4/32,5.6.7.0/24"
#
# Admin credentials are read from AWS Secrets Manager — no hardcoded password.
set -euo pipefail

# ---------- config ----------
KC_URL="https://sso.example.com"
REALM="kiro-idp"
FLOW_ALIAS="ip-restricted-browser"
FORMS_SUBFLOW_ALIAS="${FLOW_ALIAS} forms"
SPI_PROVIDER_ID="ip-check-authenticator"
CONFIG_ALIAS="ip-whitelist"

KC_REGION="eu-central-1"
KC_ADMIN_SECRET_ID="prod/kc/admin"

# default whitelist - override via first argument
DEFAULT_IPS="203.0.113.10/32"
ALLOWED_IPS="${1:-${DEFAULT_IPS}}"

echo "=== Configuring IP-restricted browser flow ==="
echo "  Realm:       ${REALM}"
echo "  Flow:       ${FLOW_ALIAS}"
echo "  Allowed IPs: ${ALLOWED_IPS}"
echo ""

# ---------- admin token ----------
KC_JSON=$(aws secretsmanager get-secret-value \
  --region "${KC_REGION}" --secret-id "${KC_ADMIN_SECRET_ID}" \
  --query SecretString --output text)
KC_USER=$(echo "${KC_JSON}" | python3 -c "import sys,json; print(json.load(sys.stdin)['username'])")
KC_PASS=$(echo "${KC_JSON}" | python3 -c "import sys,json; print(json.load(sys.stdin)['password'])")

TOKEN=$(curl -sf -X POST "${KC_URL}/realms/master/protocol/openid-connect/token" \
    --data-urlencode "username=${KC_USER}" \
    --data-urlencode "password=${KC_PASS}" \
    --data-urlencode "grant_type=password" \
    --data-urlencode "client_id=admin-cli" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

BASE="${KC_URL}/admin/realms/${REALM}"

kc_get() {
    curl -sf -H "Authorization: Bearer ${TOKEN}" "${BASE}$1"
}
kc_post_json() {
    local path=$1; local body=$2
    curl -s -o /tmp/kc.out -w "%{http_code}" \
        -X POST "${BASE}${path}" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        -d "${body}"
}
kc_put_json() {
    local path=$1; local body=$2
    curl -s -o /tmp/kc.out -w "%{http_code}" \
        -X PUT "${BASE}${path}" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        -d "${body}"
}

# ---------- 1. SPI 校验 ----------
echo "[Step 1] 验证 ${SPI_PROVIDER_ID} SPI 已加载..."
HAS_SPI=$(curl -sf "${KC_URL}/admin/serverinfo" -H "Authorization: Bearer ${TOKEN}" \
  | python3 -c "
import sys, json
p = json.load(sys.stdin).get('providers',{}).get('authenticator',{}).get('providers',{})
print('yes' if '${SPI_PROVIDER_ID}' in p else 'no')")
if [ "$HAS_SPI" != "yes" ]; then
    echo "  ❌ SPI 未加载。确保镜像里有 /opt/keycloak/providers/ip-check-authenticator.jar"
    exit 1
fi
echo "  ✅ SPI 已加载"

# ---------- 2. 创建 flow（幂等） ----------
echo ""
echo "[Step 2] 创建 flow '${FLOW_ALIAS}'（不存在则克隆 browser）..."
EXIST_FLOW=$(kc_get "/authentication/flows" \
  | python3 -c "
import sys, json
for f in json.load(sys.stdin):
    if f.get('alias') == '${FLOW_ALIAS}':
        print('yes'); break
else:
    print('no')")
if [ "$EXIST_FLOW" = "yes" ]; then
    echo "  ⚠️ flow 已存在，跳过创建"
else
    HTTP=$(kc_post_json "/authentication/flows/browser/copy" "{\"newName\":\"${FLOW_ALIAS}\"}")
    if [ "$HTTP" != "201" ]; then
        echo "  ❌ 创建失败 HTTP ${HTTP}"
        cat /tmp/kc.out
        exit 1
    fi
    echo "  ✅ 已克隆 browser flow"
fi

# ---------- 3. 在 forms 子流程里加 IP Check（幂等） ----------
echo ""
echo "[Step 3] 在 '${FORMS_SUBFLOW_ALIAS}' 子流程里添加 IP Check..."
EXEC_ID=$(kc_get "/authentication/flows/${FLOW_ALIAS}/executions" \
  | python3 -c "
import sys, json
for e in json.load(sys.stdin):
    if e.get('providerId') == '${SPI_PROVIDER_ID}':
        print(e['id']); break")
if [ -n "$EXEC_ID" ]; then
    echo "  ⚠️ IP Check execution 已存在 (${EXEC_ID})"
else
    # URL 编码子流程别名（空格 -> %20）
    SUBFLOW_ENCODED=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${FORMS_SUBFLOW_ALIAS}'))")
    HTTP=$(kc_post_json "/authentication/flows/${SUBFLOW_ENCODED}/executions/execution" \
        "{\"provider\":\"${SPI_PROVIDER_ID}\"}")
    if [ "$HTTP" != "201" ]; then
        echo "  ❌ 添加 execution 失败 HTTP ${HTTP}"
        cat /tmp/kc.out; exit 1
    fi
    EXEC_ID=$(kc_get "/authentication/flows/${FLOW_ALIAS}/executions" \
      | python3 -c "
import sys, json
for e in json.load(sys.stdin):
    if e.get('providerId') == '${SPI_PROVIDER_ID}':
        print(e['id']); break")
    echo "  ✅ 已添加 execution (${EXEC_ID})"
fi

# 把 requirement 强制设为 REQUIRED
echo ""
echo "[Step 4] 把 IP Check 设为 REQUIRED..."
EXEC=$(kc_get "/authentication/flows/${FLOW_ALIAS}/executions" \
  | python3 -c "
import sys, json
for e in json.load(sys.stdin):
    if e.get('providerId') == '${SPI_PROVIDER_ID}':
        e['requirement'] = 'REQUIRED'
        print(json.dumps(e)); break")
HTTP=$(kc_put_json "/authentication/flows/${FLOW_ALIAS}/executions" "${EXEC}")
if [ "$HTTP" = "204" ] || [ "$HTTP" = "200" ]; then
    echo "  ✅ requirement=REQUIRED"
else
    echo "  ❌ PUT 失败 HTTP ${HTTP}"; cat /tmp/kc.out; exit 1
fi

# ---------- 4. 创建/更新 config ----------
echo ""
echo "[Step 5] 设置 allowed_ips=${ALLOWED_IPS}..."
CFG_ID=$(kc_get "/authentication/flows/${FLOW_ALIAS}/executions" \
  | python3 -c "
import sys, json
for e in json.load(sys.stdin):
    if e.get('providerId') == '${SPI_PROVIDER_ID}':
        print(e.get('authenticationConfig','')); break")

CFG_BODY=$(python3 -c "
import json
print(json.dumps({'alias':'${CONFIG_ALIAS}','config':{'allowed_ips':'${ALLOWED_IPS}'}}))
")

if [ -z "$CFG_ID" ]; then
    # 新建
    HTTP=$(kc_post_json "/authentication/executions/${EXEC_ID}/config" "${CFG_BODY}")
    if [ "$HTTP" != "201" ]; then
        echo "  ❌ 创建 config 失败 HTTP ${HTTP}"; cat /tmp/kc.out; exit 1
    fi
    CFG_ID=$(kc_get "/authentication/flows/${FLOW_ALIAS}/executions" \
      | python3 -c "
import sys, json
for e in json.load(sys.stdin):
    if e.get('providerId') == '${SPI_PROVIDER_ID}':
        print(e.get('authenticationConfig','')); break")
    echo "  ✅ config 已创建 (${CFG_ID})"
else
    # 更新
    FULL_CFG=$(python3 -c "
import json
print(json.dumps({'id':'${CFG_ID}','alias':'${CONFIG_ALIAS}','config':{'allowed_ips':'${ALLOWED_IPS}'}}))
")
    HTTP=$(kc_put_json "/authentication/config/${CFG_ID}" "${FULL_CFG}")
    if [ "$HTTP" != "204" ] && [ "$HTTP" != "200" ]; then
        echo "  ❌ 更新 config 失败 HTTP ${HTTP}"; cat /tmp/kc.out; exit 1
    fi
    echo "  ✅ config 已更新 (${CFG_ID})"
fi

# ---------- 5. 绑定到 realm browserFlow ----------
echo ""
echo "[Step 6] 把 realm ${REALM} 的 browserFlow 切到 ${FLOW_ALIAS}..."
CURRENT=$(kc_get "" | python3 -c "import sys,json; print(json.load(sys.stdin)['browserFlow'])")
if [ "$CURRENT" = "${FLOW_ALIAS}" ]; then
    echo "  ⚠️ 已经是 ${FLOW_ALIAS}，跳过"
else
    HTTP=$(kc_put_json "" "{\"browserFlow\":\"${FLOW_ALIAS}\"}")
    if [ "$HTTP" != "204" ] && [ "$HTTP" != "200" ]; then
        echo "  ❌ PUT realm 失败 HTTP ${HTTP}"; cat /tmp/kc.out; exit 1
    fi
    echo "  ✅ browserFlow 已切换（之前是 ${CURRENT}）"
fi

# ---------- 6. 汇总 ----------
echo ""
echo "============================================================"
echo "  ✅ IP whitelist flow 配置完成"
echo "============================================================"
echo "  Realm:        ${REALM}"
echo "  browserFlow:  ${FLOW_ALIAS}"
echo "  allowed_ips:  ${ALLOWED_IPS}"
echo "  config id:    ${CFG_ID}"
echo "  execution id: ${EXEC_ID}"
echo ""
echo "  验证方式："
echo "    从白名单内 IP 访问 Keycloak 登录页 -> 应正常显示登录表单"
echo "    从白名单外 IP    -> 应显示 'Access denied: your IP xxx is not in the allowed list'"
echo ""
echo "  更新白名单（以后运维）："
echo "    bash $(basename $0) \"203.0.113.10/32,203.0.113.0/24\""
echo "============================================================"
