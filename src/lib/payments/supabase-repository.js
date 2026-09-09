export function createPaymentsRepository(admin) {
  if (!admin?.from || !admin?.rpc) throw new Error("Supabase admin client is required");
  return {
    async findCredentialByHash(hash) {
      const { data, error } = await admin
        .from("payment_api_credentials")
        .select("id, application_id, tenant_id, environment, status, revoked_at, expires_at, credential_provenance")
        .eq("credential_hash", hash)
        .maybeSingle();
      if (error) throw error;
      return data;
    },
    async findApplication(applicationId, tenantId) {
      const { data, error } = await admin
        .from("payment_api_applications")
        .select("id, tenant_id, environment, status")
        .eq("id", applicationId)
        .eq("tenant_id", tenantId)
        .maybeSingle();
      if (error) throw error;
      return data;
    },
    async findTenant(tenantId) {
      const { data, error } = await admin
        .from("tenants")
        .select("id, ativo")
        .eq("id", tenantId)
        .maybeSingle();
      if (error) throw error;
      return data;
    },
    async listCredentialScopes(credentialId, tenantId) {
      const { data, error } = await admin
        .from("payment_api_credential_scopes")
        .select("scope_code")
        .eq("credential_id", credentialId)
        .eq("tenant_id", tenantId);
      if (error) throw error;
      return data || [];
    },
    async auditAuthAttempt({ credentialId, applicationId, tenantId, requestId, success, reason }) {
      const { error } = await admin.rpc("payment_api_audit_auth_attempt", {
        p_credential_id: credentialId,
        p_application_id: applicationId,
        p_tenant_id: tenantId,
        p_request_id: requestId,
        p_success: success,
        p_reason: reason,
      });
      if (error) throw error;
    },
    async touchCredential({ credentialId, requestId }) {
      const { error } = await admin.rpc("payment_api_touch_credential", {
        p_credential_id: credentialId,
        p_request_id: requestId,
      });
      if (error) throw error;
    },
  };
}
