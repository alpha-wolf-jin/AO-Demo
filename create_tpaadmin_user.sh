#!/bin/bash
set -e

KEYCLOAK_HOST="keycloak-keycloak.apps.hub.lab.com"
REALM="rhtpa"
USERNAME="tpaadmin"
PASSWORD="RedHat123!"

echo "=== 1. Acquiring Master Realm Admin Token ==="
ADMIN_TOKEN=$(curl -sk -X POST "https://${KEYCLOAK_HOST}/realms/master/protocol/openid-connect/token" \
  -d "username=admin" -d "password=AdminPass123" -d "grant_type=password" -d "client_id=admin-cli" | jq -r '.access_token')

if [ -z "$ADMIN_TOKEN" ] || [ "$ADMIN_TOKEN" = "null" ]; then
  echo "[ERROR] Failed to obtain admin token from master realm."
  exit 1
fi
echo "[SUCCESS] Master admin token acquired."

echo ""
echo "=== 2. Creating User '${USERNAME}' in Realm '${REALM}' ==="
USER_CHECK=$(curl -sk -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  "https://${KEYCLOAK_HOST}/admin/realms/${REALM}/users?username=${USERNAME}" | jq -r '.[0].id // empty')

if [ -z "$USER_CHECK" ]; then
  curl -sk -X POST "https://${KEYCLOAK_HOST}/admin/realms/${REALM}/users" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
      \"username\": \"${USERNAME}\",
      \"enabled\": true,
      \"email\": \"tpaadmin@example.com\",
      \"firstName\": \"TPA\",
      \"lastName\": \"Admin\",
      \"emailVerified\": true,
      \"credentials\": [{
        \"type\": \"password\",
        \"value\": \"${PASSWORD}\",
        \"temporary\": false
      }]
    }"
  echo "[SUCCESS] User '${USERNAME}' created."
else
  echo "[INFO] User '${USERNAME}' already exists. Updating password..."
  curl -sk -X PUT "https://${KEYCLOAK_HOST}/admin/realms/${REALM}/users/${USER_CHECK}/reset-password" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
      \"type\": \"password\",
      \"value\": \"${PASSWORD}\",
      \"temporary\": false
    }"
  echo "[SUCCESS] Password reset for '${USERNAME}'."
fi

echo ""
echo "=== 3. Assigning Roles to '${USERNAME}' ==="
USER_ID=$(curl -sk -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  "https://${KEYCLOAK_HOST}/admin/realms/${REALM}/users?username=${USERNAME}" | jq -r '.[0].id')

ALL_ROLES=$(curl -sk -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  "https://${KEYCLOAK_HOST}/admin/realms/${REALM}/roles")

curl -sk -X POST "https://${KEYCLOAK_HOST}/admin/realms/${REALM}/users/${USER_ID}/role-mappings/realm" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$ALL_ROLES"

echo "[SUCCESS] Granted all realm roles to '${USERNAME}'."
