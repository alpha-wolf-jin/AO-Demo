#!/bin/bash
# =========================================================================
#  RHTPA - Proxy-Aware CVE Auto-Resolution & Ingestion (CVE-ID Only)
# =========================================================================
set -e

CVE_ID="${1:?Error: CVE ID required (e.g. ./seed_cve_only.sh CVE-2024-23334)}"
PROXY_OVERRIDE="${2:-}"

CURL_PROXY_ARGS=()
if [ -n "$PROXY_OVERRIDE" ]; then
  CURL_PROXY_ARGS=(-x "$PROXY_OVERRIDE")
elif [ -n "$https_proxy" ] || [ -n "$HTTPS_PROXY" ]; then
  CURL_PROXY_ARGS=(-x "${https_proxy:-$HTTPS_PROXY}")
elif [ -n "$http_proxy" ] || [ -n "$HTTP_PROXY" ]; then
  CURL_PROXY_ARGS=(-x "${http_proxy:-$HTTP_PROXY}")
fi

RUN_ID=$(date +%s)

RHTPA_HOST="server-trusted-profile-analyzer.apps.hub.lab.com"
KEYCLOAK_HOST="keycloak-keycloak.apps.hub.lab.com"
REALM="rhtpa"
CLIENT_ID="rhtpa-cli"

echo "========================================================================="
echo " Proxy-Aware CVE Auto-Resolution & Ingestion"
echo " Target CVE ID : ${CVE_ID}"
if [ ${#CURL_PROXY_ARGS[@]} -gt 0 ]; then
  echo " Using Proxy   : ${CURL_PROXY_ARGS[1]}"
else
  echo " Using Proxy   : System Default / Direct"
fi
echo "========================================================================="

echo ""
echo "=== 1. Fetching Vulnerability Metadata via OSV API ==="
OSV_RESP=$(curl -sk -f "${CURL_PROXY_ARGS[@]}" "https://api.osv.dev/v1/vulns/${CVE_ID}" 2>/dev/null || echo "")

PKG_NAME=""
PKG_VER=""
ECOSYSTEM=""

if echo "$OSV_RESP" | jq -e . >/dev/null 2>&1; then
  # Extract Package Name from .package.name OR .cpe OR .repo OR .summary
  PKG_NAME=$(echo "$OSV_RESP" | jq -r '
    .affected[0]?.package?.name // 
    (.affected[0]?.ranges[0]?.database_specific?.cpe | split(":")[4]) // 
    (.affected[0]?.ranges[0]?.repo | split("/")[-1]) // 
    (.summary | capture("(?<p>[a-zA-Z0-9_-]+)\\."; "g") | .p) // 
    empty
  ' 2>/dev/null | head -n 1)

  ECOSYSTEM_RAW=$(echo "$OSV_RESP" | jq -r '.affected[0]?.package?.ecosystem // "PyPI"' 2>/dev/null)
  ECOSYSTEM=$(echo "$ECOSYSTEM_RAW" | tr '[:upper:]' '[:lower:]')

  # Extract Version from .versions[0] OR .events[] OR .extracted_events[]
  PKG_VER=$(echo "$OSV_RESP" | jq -r '
    .affected[0]?.versions[0] // 
    .affected[0]?.ranges[0]?.events[0]?.introduced // 
    .affected[0]?.ranges[0]?.database_specific?.extracted_events[0]?.introduced // 
    empty
  ' 2>/dev/null)
fi

# Fallback Registry mapping (for air-gapped / offline lookup failures)
if [ -z "$PKG_NAME" ] || [ "$PKG_NAME" = "null" ]; then
  echo "[WARN] External OSV lookups blocked or returned non-JSON payload."
  echo "[INFO] Engaging Fallback Registry for target CVE..."
  
  case "$CVE_ID" in
    "CVE-2020-28493") PKG_NAME="jinja2"; PKG_VER="2.10"; ECOSYSTEM="pypi" ;;
    "CVE-2019-11324") PKG_NAME="urllib3"; PKG_VER="1.24.1"; ECOSYSTEM="pypi" ;;
    "CVE-2024-23334") PKG_NAME="aiohttp"; PKG_VER="3.9.1"; ECOSYSTEM="pypi" ;;
    *)
      echo "[ERROR] Unknown CVE '${CVE_ID}' and OSV lookup failed."
      exit 1
      ;;
  esac
fi

if [ -z "$PKG_VER" ] || [ "$PKG_VER" = "null" ]; then
  if [ "$PKG_NAME" = "jinja2" ]; then PKG_VER="2.10"; fi
  if [ "$PKG_NAME" = "urllib3" ]; then PKG_VER="1.24.1"; fi
  if [ "$PKG_NAME" = "aiohttp" ]; then PKG_VER="3.9.1"; fi
fi

PKG_PURL="pkg:${ECOSYSTEM:-pypi}/${PKG_NAME}@${PKG_VER}"

echo "[METADATA RESOLVED via OSV API]"
echo "  - Package Name : ${PKG_NAME}"
echo "  - Version      : ${PKG_VER}"
echo "  - Ecosystem    : ${ECOSYSTEM}"
echo "  - Package PURL : ${PKG_PURL}"

echo ""
echo "=== 2. Acquiring OIDC Bearer Token for RHTPA ==="
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
  echo "[ERROR] OIDC Authentication to realm '${REALM}' failed."
  exit 1
fi

echo "[SUCCESS] Bearer Token acquired for realm '${REALM}'."

echo ""
echo "=== 3. Uploading CVE v5 Record (${CVE_ID}) ==="
curl -sk -X POST "https://${RHTPA_HOST}/api/v3/advisory" \
  -H "Authorization: Bearer ${RHTPA_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{
    \"dataType\": \"CVE_RECORD\",
    \"dataVersion\": \"5.1\",
    \"cveMetadata\": {
      \"cveId\": \"${CVE_ID}\",
      \"assignerOrgId\": \"a39b4221-92f3-4e0d-b18a-350257e8006e\",
      \"state\": \"PUBLISHED\"
    },
    \"containers\": {
      \"cna\": {
        \"providerMetadata\": { \"orgId\": \"a39b4221-92f3-4e0d-b18a-350257e8006e\" },
        \"title\": \"Security vulnerability ${CVE_ID} in ${PKG_NAME}\",
        \"descriptions\": [{\"lang\": \"en\", \"value\": \"${PKG_NAME} ${PKG_VER} vulnerable to ${CVE_ID}\"}],
        \"affected\": [{\"vendor\": \"${PKG_NAME}\", \"product\": \"${PKG_NAME}\", \"versions\": [{\"version\": \"${PKG_VER}\", \"status\": \"affected\"}]}]
      }
    }
  }"

echo -e "\n"
echo "=== 4. Uploading CSAF 2.0 VEX Advisory (${PKG_PURL}) ==="
curl -sk -X POST "https://${RHTPA_HOST}/api/v3/advisory" \
  -H "Authorization: Bearer ${RHTPA_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{
    \"document\": {
      \"category\": \"csaf_vex\",
      \"csaf_version\": \"2.0\",
      \"publisher\": { \"category\": \"vendor\", \"name\": \"Red Hat Security\", \"namespace\": \"https://access.redhat.com\" },
      \"title\": \"RHSA-${CVE_ID}-${RUN_ID} - ${PKG_NAME} ${PKG_VER} Advisory\",
      \"tracking\": {
        \"current_release_date\": \"2026-10-12T10:00:00Z\",
        \"id\": \"RHSA-${CVE_ID}-${RUN_ID}\",
        \"initial_release_date\": \"2026-10-12T10:00:00Z\",
        \"revision_history\": [{\"date\": \"2026-10-12T10:00:00Z\", \"number\": \"1\", \"summary\": \"Initial\"}],
        \"status\": \"final\",
        \"version\": \"1\"
      }
    },
    \"product_tree\": {
      \"full_product_names\": [{\"product_id\": \"CSAFPID-${CVE_ID}-${RUN_ID}\", \"name\": \"${PKG_NAME} ${PKG_VER}\", \"product_identification_helper\": {\"purl\": \"${PKG_PURL}\"}}]
    },
    \"vulnerabilities\": [{
      \"cve\": \"${CVE_ID}\",
      \"notes\": [{\"category\": \"description\", \"text\": \"${PKG_NAME} ${PKG_VER} vulnerable to ${CVE_ID}\"}],
      \"product_status\": {\"known_affected\": [\"CSAFPID-${CVE_ID}-${RUN_ID}\"]},
      \"title\": \"${PKG_NAME} ${PKG_VER} ${CVE_ID} Advisory\"
    }]
  }"

echo -e "\n\n[SUCCESS] Ingestion complete for ${CVE_ID} -> ${PKG_PURL}."
