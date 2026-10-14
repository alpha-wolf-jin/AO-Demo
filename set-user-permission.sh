# 1. Fetch Admin Token
ADMIN_TOKEN=$(curl -sk -X POST "https://keycloak-keycloak.apps.hub.lab.com/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=admin" \
  -d "password=AdminPass123" \
  -d "grant_type=password" \
  -d "client_id=admin-cli" | jq -r '.access_token')

# 2. Get or Create 'tpaadmin' User
USER_ID=$(curl -sk "https://keycloak-keycloak.apps.hub.lab.com/admin/realms/rhtpa/users?username=tpaadmin" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" | jq -r '.[0].id' 2>/dev/null || true)

if [ -z "$USER_ID" ] || [ "$USER_ID" = "null" ]; then
  curl -sk -X POST "https://keycloak-keycloak.apps.hub.lab.com/admin/realms/rhtpa/users" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"username":"tpaadmin","enabled":true,"email":"tpaadmin@lab.com","firstName":"TPA","lastName":"Admin"}'
  
  USER_ID=$(curl -sk "https://keycloak-keycloak.apps.hub.lab.com/admin/realms/rhtpa/users?username=tpaadmin" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" | jq -r '.[0].id')
fi

# 3. Explicitly Reset Password for tpaadmin
curl -sk -X PUT "https://keycloak-keycloak.apps.hub.lab.com/admin/realms/rhtpa/users/${USER_ID}/reset-password" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"type":"password","value":"RedHat123!","temporary":false}'

# 4. Assign Realm Roles to tpaadmin
ALL_REALM_ROLES=$(curl -sk "https://keycloak-keycloak.apps.hub.lab.com/admin/realms/rhtpa/roles" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}")

ROLES_PAYLOAD=$(echo "$ALL_REALM_ROLES" | jq '[.[] | select(.name as $n | ["admin","manager","create:document","read:document","create.sbom","read.sbom"] | index($n))]')

curl -sk -X POST "https://keycloak-keycloak.apps.hub.lab.com/admin/realms/rhtpa/users/${USER_ID}/role-mappings/realm" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$ROLES_PAYLOAD"

# 5. Attach Client Scopes to 'rhtpa-frontend'
FRONTEND_UUID=$(curl -sk "https://keycloak-keycloak.apps.hub.lab.com/admin/realms/rhtpa/clients?clientId=rhtpa-frontend" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" | jq -r '.[0].id')

SCOPES=("create:document" "read:document" "create.sbom" "read.sbom")
for sc in "${SCOPES[@]}"; do
  SCOPE_ID=$(curl -sk "https://keycloak-keycloak.apps.hub.lab.com/admin/realms/rhtpa/client-scopes" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" | jq -r ".[] | select(.name == \"${sc}\") | .id" 2>/dev/null || true)

  if [ -n "$SCOPE_ID" ] && [ "$SCOPE_ID" != "null" ]; then
    curl -sk -X PUT "https://keycloak-keycloak.apps.hub.lab.com/admin/realms/rhtpa/clients/${FRONTEND_UUID}/default-client-scopes/${SCOPE_ID}" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" >/dev/null 2>&1 || true
  fi
done

echo "User 'tpaadmin' password set and 'rhtpa-frontend' scopes configured."
