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
    async beginIdempotency({ tenantId, applicationId, method, operation, key, fingerprint, requestId, leaseSeconds }) {
      const { data, error } = await admin.rpc("payment_api_begin_idempotency", {
        p_tenant_id: tenantId,
        p_application_id: applicationId,
        p_http_method: method,
        p_operation: operation,
        p_idempotency_key: key,
        p_request_fingerprint: fingerprint,
        p_request_id: requestId ?? null,
        p_lease_seconds: leaseSeconds ?? 60,
      });
      if (error) throw error;
      return data;
    },
    async createCustomerAtomic({ idempotencyRecordId, leaseToken, name, email, externalReference, requestId }) {
      const { data, error } = await admin.rpc("payment_api_create_customer_atomic", {
        p_idempotency_record_id: idempotencyRecordId,
        p_lease_token: leaseToken,
        p_name: name,
        p_email: email,
        p_external_reference: externalReference,
        p_request_id: requestId ?? null,
      });
      if (error) throw error;
      return data;
    },
    /**
     * @param {{recordId: string, leaseToken: string, status: number, body: object, failureKind: "deterministic" | "transient", errorCode: string, requestId?: string | null, retryAfterSeconds?: number}} input
     */
    async failIdempotency({ recordId, leaseToken, status, body, failureKind, errorCode, requestId, retryAfterSeconds }) {
      const { data, error } = await admin.rpc("payment_api_fail_idempotency", {
        p_record_id: recordId,
        p_lease_token: leaseToken,
        p_response_status: status,
        p_response_body: body,
        p_failure_kind: failureKind,
        p_error_code: errorCode,
        p_request_id: requestId ?? null,
        p_retry_after_seconds: retryAfterSeconds ?? 0,
      });
      if (error) throw error;
      return data;
    },
  };
}
