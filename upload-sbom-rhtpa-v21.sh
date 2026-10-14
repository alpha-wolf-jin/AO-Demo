#!/bin/bash
# =========================================================================
# Red Hat Trusted Profile Analyzer - SBOM Upload & Full Auth Resolution (v21)
# File Name: upload-sbom-rhtpa-v21.sh
# =========================================================================
set -e

SBOM_FILE="${1:-sbom.json}"
NAMESPACE="trusted-profile-analyzer"
KEYCLOAK_NS="keycloak"

if [ ! -f "$SBOM_FILE" ]; then
    echo "[ERROR] SBOM file '$SBOM_FILE' not found!"
    echo "Usage: $0 <path-to-sbom.json>"
    exit 1
fi

echo "========================================================================="
echo " Red Hat Trusted Profile Analyzer - SBOM Upload & Auth Resolution (v21)  "
echo "========================================================================="

echo "=== 1. Ensuring RHTPA Service & Passthrough Route ==="
if ! oc get service server -n "$NAMESPACE" >/dev/null 2>&1; then
    echo "Creating 'server' Service on port 8080..."
    oc expose deployment/server -n "$NAMESPACE" --port=8080 --target-port=8080 --name=server
fi

ROUTE_TERM=$(oc get route server -n "$NAMESPACE" -o jsonpath='{.spec.tls.termination}' 2>/dev/null || true)
if [ "$ROUTE_TERM" != "passthrough" ]; then
    echo "Recreating Route 'server' with Passthrough TLS termination..."
    oc delete route server -n "$NAMESPACE" --ignore-not-found
    oc create route passthrough server --service=server --port=8080 -n "$NAMESPACE"
fi

RHTPA_HOST=$(oc get route server -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || true)
echo "Target RHTPA Host: https://${RHTPA_HOST}"

echo "=== 2. Resolving Keycloak Host & Fetching Admin Token ==="
KEYCLOAK_HOST=$(oc get route keycloak -n "$KEYCLOAK_NS" -o jsonpath='{.spec.host}' 2>/dev/null || true)
echo "Target Keycloak Host: https://${KEYCLOAK_HOST}"

echo "Fetching Keycloak Master Admin Token..."
ADMIN_TOKEN=$(curl -sk -X POST "https://${KEYCLOAK_HOST}/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=admin" \
  -d "password=AdminPass123" \
  -d "grant_type=password" \
  -d "client_id=admin-cli" | jq -r '.access_token' 2>/dev/null || true)

if [ -z "$ADMIN_TOKEN" ] || [ "$ADMIN_TOKEN" = "null" ]; then
    echo "[ERROR] Could not authenticate with Keycloak master realm as 'admin'."
    exit 1
fi
echo "Master Admin Token acquired successfully."

echo "=== 3. Ensuring Realm 'rhtpa' Exists ==="
RHTPA_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "https://${KEYCLOAK_HOST}/realms/rhtpa/.well-known/openid-configuration" || echo "000")

if [ "$RHTPA_CODE" != "200" ]; then
    echo "Realm 'rhtpa' missing (HTTP $RHTPA_CODE). Provisioning realm 'rhtpa'..."
    cat <<EOF > /tmp/rhtpa_realm.json
{
  "realm": "rhtpa",
  "enabled": true,
  "displayName": "Red Hat Trusted Profile Analyzer Realm"
}
EOF
    curl -sk -X POST "https://${KEYCLOAK_HOST}/admin/realms" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" \
      -H "Content-Type: application/json" \
      -d @/tmp/rhtpa_realm.json >/dev/null 2>&1 || true
    echo "Realm 'rhtpa' provisioned."
else
    echo "Realm 'rhtpa' is active and responding."
fi

echo "=== 4. Ensuring Client 'rhtpa-cli' Exists in Realm 'rhtpa' ==="
CLI_SEC=$(oc get secret oidc-cli -n "$NAMESPACE" -o jsonpath='{.data.client-secret}' 2>/dev/null | base64 -d 2>/dev/null || echo "ClientSecret123")

CLIENT_UUID=$(curl -sk "https://${KEYCLOAK_HOST}/admin/realms/rhtpa/clients?clientId=rhtpa-cli" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" | jq -r '.[0].id' 2>/dev/null || true)

if [ -z "$CLIENT_UUID" ] || [ "$CLIENT_UUID" = "null" ]; then
    echo "Creating client 'rhtpa-cli'..."
    cat <<EOF > /tmp/rhtpa_cli_client.json
{
  "clientId": "rhtpa-cli",
  "secret": "${CLI_SEC}",
  "enabled": true,
  "publicClient": false,
  "serviceAccountsEnabled": true,
  "directAccessGrantsEnabled": true,
  "standardFlowEnabled": true
}
EOF
    curl -sk -X POST "https://${KEYCLOAK_HOST}/admin/realms/rhtpa/clients" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" \
      -H "Content-Type: application/json" \
      -d @/tmp/rhtpa_cli_client.json >/dev/null 2>&1 || true

    CLIENT_UUID=$(curl -sk "https://${KEYCLOAK_HOST}/admin/realms/rhtpa/clients?clientId=rhtpa-cli" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" | jq -r '.[0].id' 2>/dev/null || true)
fi

echo "Client 'rhtpa-cli' UUID: ${CLIENT_UUID}"

echo "=== 5. Provisioning Realm Roles & Assigning to Service Account ==="
echo "=== 5. Provisioning Realm Roles, Client Scopes & Service Account Mappings ==="
if [ -n "$CLIENT_UUID" ] && [ "$CLIENT_UUID" != "null" ]; then
    # 1. Clean up existing mappers on rhtpa-cli
    MAPPERS=$(curl -sk "https://${KEYCLOAK_HOST}/admin/realms/rhtpa/clients/${CLIENT_UUID}/protocol-mappers/models" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" | jq -r '.[].id' 2>/dev/null || true)
    for mid in $MAPPERS; do
        curl -sk -X DELETE "https://${KEYCLOAK_HOST}/admin/realms/rhtpa/clients/${CLIENT_UUID}/protocol-mappers/models/${mid}" \
          -H "Authorization: Bearer ${ADMIN_TOKEN}" >/dev/null 2>&1 || true
    done

    # 2. Add Audience Mappers
    for aud in "rhtpa-cli" "rhtpa-frontend"; do
      cat <<EOF > /tmp/mapper_aud_${aud}.json
{
  "name": "rhtpa-aud-${aud}",
  "protocol": "openid-connect",
  "protocolMapper": "oidc-audience-mapper",
  "config": {
    "included.client.audience": "${aud}",
    "access.token.claim": "true",
    "id.token.claim": "true"
  }
}
EOF
      curl -sk -X POST "https://${KEYCLOAK_HOST}/admin/realms/rhtpa/clients/${CLIENT_UUID}/protocol-mappers/models" \
        -H "Authorization: Bearer ${ADMIN_TOKEN}" \
        -H "Content-Type: application/json" \
        -d @/tmp/mapper_aud_${aud}.json >/dev/null 2>&1 || true
    done

    # 3. Create Realm Roles if missing
    ROLES=("admin" "manager" "create:document" "read:document" "create.sbom" "read.sbom")
    for r in "${ROLES[@]}"; do
      curl -sk -X POST "https://${KEYCLOAK_HOST}/admin/realms/rhtpa/roles" \
        -H "Authorization: Bearer ${ADMIN_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"name\": \"${r}\"}" >/dev/null 2>&1 || true
    done

    # 4. Get Service Account User ID for rhtpa-cli & Assign Realm Roles
    SA_USER_ID=$(curl -sk "https://${KEYCLOAK_HOST}/admin/realms/rhtpa/clients/${CLIENT_UUID}/service-account-user" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" | jq -r '.id' 2>/dev/null || true)

    if [ -n "$SA_USER_ID" ] && [ "$SA_USER_ID" != "null" ]; then
      ALL_REALM_ROLES=$(curl -sk "https://${KEYCLOAK_HOST}/admin/realms/rhtpa/roles" \
        -H "Authorization: Bearer ${ADMIN_TOKEN}" 2>/dev/null || true)
      
      ROLES_PAYLOAD=$(echo "$ALL_REALM_ROLES" | jq '[.[] | select(.name as $n | ["admin","manager","create:document","read:document","create.sbom","read.sbom"] | index($n))]')

      curl -sk -X POST "https://${KEYCLOAK_HOST}/admin/realms/rhtpa/users/${SA_USER_ID}/role-mappings/realm" \
        -H "Authorization: Bearer ${ADMIN_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$ROLES_PAYLOAD" >/dev/null 2>&1 || true
    fi

    # 5. Create Keycloak Client Scopes & Attach as Default Client Scopes to rhtpa-cli
    SCOPES=("create:document" "read:document" "create.sbom" "read.sbom")
    for sc in "${SCOPES[@]}"; do
      # Create Realm Client Scope
      curl -sk -X POST "https://${KEYCLOAK_HOST}/admin/realms/rhtpa/client-scopes" \
        -H "Authorization: Bearer ${ADMIN_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"name\": \"${sc}\", \"protocol\": \"openid-connect\"}" >/dev/null 2>&1 || true

      # Fetch Scope ID
      SCOPE_ID=$(curl -sk "https://${KEYCLOAK_HOST}/admin/realms/rhtpa/client-scopes" \
        -H "Authorization: Bearer ${ADMIN_TOKEN}" | jq -r ".[] | select(.name == \"${sc}\") | .id" 2>/dev/null || true)

      # Attach as Default Client Scope to rhtpa-cli
      if [ -n "$SCOPE_ID" ] && [ "$SCOPE_ID" != "null" ]; then
        curl -sk -X PUT "https://${KEYCLOAK_HOST}/admin/realms/rhtpa/clients/${CLIENT_UUID}/default-client-scopes/${SCOPE_ID}" \
          -H "Authorization: Bearer ${ADMIN_TOKEN}" >/dev/null 2>&1 || true
      fi
    done
fi

echo "=== 6. Patching ConfigMaps & Updating Server Deployment OIDC Issuer ==="
KEYCLOAK_ISSUER="https://${KEYCLOAK_HOST}/realms/rhtpa"

# Update any server auth configmaps containing legacy oauth URLs
for cm in $(oc get configmap -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true); do
  if oc get configmap "$cm" -n "$NAMESPACE" -o yaml 2>/dev/null | grep -i -q "oauth"; then
    echo "Updating ConfigMap '$cm' with Keycloak Issuer URL..."
    oc get configmap "$cm" -n "$NAMESPACE" -o yaml | \
      sed "s|https://oauth[^\"]*|${KEYCLOAK_ISSUER}|g" | \
      oc apply -f - >/dev/null 2>&1 || true
  fi
done

# Ensure Router CA & Service CA Bundle ConfigMap
ROUTER_CA=$(oc get configmap default-ingress-cert -n openshift-config-managed -o jsonpath='{.data.ca-bundle\.crt}' 2>/dev/null || true)
if [ -z "$ROUTER_CA" ]; then
    ROUTER_CA=$(oc get configmap router-ca -n openshift-config-managed -o jsonpath='{.data.ca-bundle\.crt}' 2>/dev/null || true)
fi
SERVICE_CA=$(oc get configmap kube-root-ca.crt -n "$NAMESPACE" -o jsonpath='{.data.ca-bundle\.crt}' 2>/dev/null || true)

COMBINED_CA="${ROUTER_CA}
${SERVICE_CA}"

oc create configmap custom-ca-bundle -n "$NAMESPACE" \
  --from-literal=ca-bundle.crt="$COMBINED_CA" \
  --dry-run=client -o yaml | oc apply -f - >/dev/null 2>&1 || true

oc set volume deployment/server -n "$NAMESPACE" \
  --add --name=custom-ca-vol \
  --type=configmap \
  --configmap-name=custom-ca-bundle \
  --mount-path=/var/run/configmaps/custom-ca \
  --overwrite >/dev/null 2>&1 || true

# Only set SSL_CERT_FILE environment variable (do NOT set OIDC_ISSUER_URL env vars)
oc set env deployment/server -n "$NAMESPACE" \
  SSL_CERT_FILE=/var/run/configmaps/custom-ca/ca-bundle.crt >/dev/null 2>&1 || true

echo "Waiting for deployment/server rollout completion..."
oc rollout status deployment/server -n "$NAMESPACE" --timeout=120s || true

echo "=== 7. Acquiring OIDC Bearer Token ==="
TOKEN_RESPONSE=$(curl -sk -X POST "https://${KEYCLOAK_HOST}/realms/rhtpa/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials" \
  -d "client_id=rhtpa-cli" \
  -d "client_secret=${CLI_SEC}")


TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.access_token' 2>/dev/null || true)

if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ]; then
    echo "Token acquired successfully!"
    PAYLOAD=$(echo "$TOKEN" | cut -d'.' -f2 | base64 -d 2>/dev/null || true)
    echo "--- Decoded Token Claims ---"
    echo "$PAYLOAD" | jq '{iss, aud, preferred_username, roles, scope, realm_access}' 2>/dev/null || echo "$PAYLOAD"
    echo "---------------------------"
else
    echo "[ERROR] Failed to acquire token from Keycloak."
    echo "Raw Keycloak Response: ${TOKEN_RESPONSE}"
    exit 1
fi

echo "=== 8. Uploading '$SBOM_FILE' to RHTPA Ingestion Endpoint ==="
RESPONSE=$(curl -k -w "\nHTTP_CODE:%{http_code}" -X POST "https://${RHTPA_HOST}/api/v3/sbom" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  --data-binary "@${SBOM_FILE}")

HTTP_CODE=$(echo "$RESPONSE" | grep "HTTP_CODE:" | cut -d':' -f2)
BODY=$(echo "$RESPONSE" | sed '/HTTP_CODE:/d')

echo "=== Submission Results ==="
echo "HTTP Status Code : $HTTP_CODE"
echo "Response Payload :"
echo "$BODY" | jq . 2>/dev/null || echo "$BODY"

if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
    echo ""
    echo "SUCCESS: '$SBOM_FILE' uploaded and registered successfully in RHTPA!"
else
    echo ""
    echo "[ERROR] SBOM upload failed with status code $HTTP_CODE."
    exit 1
fi
