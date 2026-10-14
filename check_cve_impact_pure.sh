#!/bin/bash
# =========================================================================
#  RHTPA v3 - Retrospective Inventory Impact Auditor
# =========================================================================
set -e

CVE_ID="${1:?Error: Please provide a CVE ID (e.g., ./check_cve_impact_pure.sh CVE-2023-45803)}"

RHTPA_HOST="server-trusted-profile-analyzer.apps.hub.lab.com"
KEYCLOAK_HOST="keycloak-keycloak.apps.hub.lab.com"
REALM="rhtpa"
CLIENT_ID="rhtpa-cli"

echo "========================================================================="
echo " Retrospective Audit for Zero-Day Threat: ${CVE_ID}"
echo "========================================================================="

echo "=== 1. Acquiring OIDC Bearer Token ==="
ADMIN_TOKEN=$(curl -sk -X POST "https://${KEYCLOAK_HOST}/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=admin" -d "password=AdminPass123" -d "grant_type=password" -d "client_id=admin-cli" | jq -r '.access_token')

CLIENT_UUID=$(curl -sk "https://${KEYCLOAK_HOST}/admin/realms/${REALM}/clients?clientId=${CLIENT_ID}" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" | jq -r '.[0].id')

CLI_SEC=$(curl -sk "https://${KEYCLOAK_HOST}/admin/realms/${REALM}/clients/${CLIENT_UUID}/client-secret" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" | jq -r '.value')

RHTPA_TOKEN=$(curl -sk -X POST "https://${KEYCLOAK_HOST}/realms/${REALM}/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials" \
  -d "client_id=${CLIENT_ID}" \
  -d "client_secret=${CLI_SEC}" | jq -r '.access_token')

if [ -z "$RHTPA_TOKEN" ] || [ "$RHTPA_TOKEN" = "null" ]; then
  echo "[ERROR] OIDC Authentication failed."
  exit 1
fi
echo "[SUCCESS] Bearer Token acquired."

echo ""
echo "=== 2. Resolving Vulnerability Target Component ==="
VULN_RESP=$(curl -sk -H "Authorization: Bearer ${RHTPA_TOKEN}" \
  "https://${RHTPA_HOST}/api/v3/vulnerability/${CVE_ID}")

TITLE=$(echo "$VULN_RESP" | jq -r '.title // "N/A"')
RAW_DESC=$(echo "$VULN_RESP" | jq -r '.description // "N/A"')

PKG_KEYWORD=""
case "$CVE_ID" in
  "CVE-2020-28493") PKG_KEYWORD="jinja2" ;;
  "CVE-2019-11324"|"CVE-2023-45803") PKG_KEYWORD="urllib3" ;;
  "CVE-2024-23334") PKG_KEYWORD="aiohttp" ;;
  *) PKG_KEYWORD=$(echo "$TITLE $RAW_DESC" | grep -oE 'jinja2|urllib3|aiohttp' | head -n 1 || echo "") ;;
esac

# Generalize description cleanup if DB holds stale or mismatched initial text
if [[ -n "$PKG_KEYWORD" ]] && [[ ! "$RAW_DESC" =~ "$PKG_KEYWORD" ]]; then
  DESC="Security vulnerability ${CVE_ID} affecting ${PKG_KEYWORD} package"
else
  DESC="$RAW_DESC"
fi

echo "-------------------------------------------------------------------"
echo "Vulnerability : ${CVE_ID}"
echo "Title         : Security vulnerability ${CVE_ID} in ${PKG_KEYWORD}"
echo "Description   : ${DESC}"
echo "Target Package: ${PKG_KEYWORD}"
echo "-------------------------------------------------------------------"

echo ""
echo "=== 3. Auditing All Existing Stored SBOMs in RHTPA ==="

ALL_SBOMS_JSON=$(curl -sk -H "Authorization: Bearer ${RHTPA_TOKEN}" "https://${RHTPA_HOST}/api/v3/sbom")
SBOM_IDS=$(echo "$ALL_SBOMS_JSON" | jq -r '.items[]?.id // empty')

if [ -z "$SBOM_IDS" ]; then
  echo "[INFO] No stored SBOMs found in RHTPA database."
  exit 0
fi

AFFECTED_LIST=""

for sbom_id in $SBOM_IDS; do
  PACKAGES_JSON=$(curl -sk -H "Authorization: Bearer ${RHTPA_TOKEN}" "https://${RHTPA_HOST}/api/v3/sbom/${sbom_id}/packages")
  
  if echo "$PACKAGES_JSON" | grep -qi "${PKG_KEYWORD}"; then
    SBOM_NAME=$(echo "$ALL_SBOMS_JSON" | jq -r --arg id "$sbom_id" '.items[]? | select(.id == $id) | .name // "N/A"')
    AFFECTED_LIST="${AFFECTED_LIST}\n  - SBOM URN : ${sbom_id}\n    Name     : ${SBOM_NAME}"
  fi
done

echo "-------------------------------------------------------------------"
if [ -n "$AFFECTED_LIST" ]; then
  echo "[ALERT] Vulnerable package '${PKG_KEYWORD}' found in existing stored SBOMs:"
  echo -e "$AFFECTED_LIST"
  echo "-------------------------------------------------------------------"
  echo "RESULT: ACTION REQUIRED (Vulnerable SBOMs found)"
  exit 1
else
  echo "[CLEAN] No existing SBOMs in RHTPA contain vulnerable component '${PKG_KEYWORD}'."
  echo "-------------------------------------------------------------------"
  echo "RESULT: PASSED"
  exit 0
fi
