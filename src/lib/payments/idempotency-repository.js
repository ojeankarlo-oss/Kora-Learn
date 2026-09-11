export function createPaymentsFoundationRepository({ rpc }) {
  if (typeof rpc !== "function") throw new TypeError("rpc function required");

  return Object.freeze({
    async registerExternalReference(input) {
      return rpc("payment_api_register_external_reference", {
        p_tenant_id: input.tenantId,
        p_application_id: input.applicationId,
        p_resource_type: input.resourceType,
        p_resource_id: input.resourceId,
        p_external_reference: input.externalReference,
        p_request_id: input.requestId ?? null,
      });
    },

    async resolveExternalReference(input) {
      return rpc("payment_api_resolve_external_reference", {
        p_tenant_id: input.tenantId,
        p_application_id: input.applicationId,
        p_resource_type: input.resourceType,
        p_external_reference: input.externalReference,
      });
    },

    async beginIdempotency(input) {
      return rpc("payment_api_begin_idempotency", {
        p_tenant_id: input.tenantId,
        p_application_id: input.applicationId,
        p_http_method: input.method,
        p_operation: input.operation,
        p_idempotency_key: input.key,
        p_request_fingerprint: input.fingerprint,
        p_request_id: input.requestId ?? null,
        p_lease_seconds: input.leaseSeconds ?? 60,
      });
    },

    async completeIdempotency(input) {
      return rpc("payment_api_complete_idempotency", {
        p_record_id: input.recordId,
        p_lease_token: input.leaseToken,
        p_response_status: input.status,
        p_response_body: input.body,
        p_request_id: input.requestId ?? null,
      });
    },

    async failIdempotency(input) {
      return rpc("payment_api_fail_idempotency", {
        p_record_id: input.recordId,
        p_lease_token: input.leaseToken,
        p_response_status: input.status,
        p_response_body: input.body,
        p_failure_kind: input.failureKind,
        p_error_code: input.errorCode,
        p_request_id: input.requestId ?? null,
        p_retry_after_seconds: input.retryAfterSeconds ?? 0,
      });
    },
  });
}
