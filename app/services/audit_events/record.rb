class AuditEvents::Record
  SENSITIVE_METADATA_KEY_PATTERN = /(?:email|token|password|secret|api_key|payload|signed_url|card)/i
  UUID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i
  REASON_CODE_PATTERN = /\A[a-z][a-z0-9_]*\z/
  METADATA_VALIDATORS = {
    "organization_role" => ->(value) { OrganizationMembership.roles.key?(value.to_s) },
    "from_role" => ->(value) { OrganizationMembership.roles.key?(value.to_s) },
    "to_role" => ->(value) { OrganizationMembership.roles.key?(value.to_s) },
    "membership_id" => ->(value) { value.is_a?(Integer) && value.positive? },
    "product_key" => ->(value) { value.to_s.match?(Product::KEY_PATTERN) },
    "product_role_key" => ->(value) { value.to_s.match?(ProductRole::KEY_PATTERN) },
    "plan_price_id" => ->(value) { value.is_a?(Integer) && value.positive? },
    "from_plan_price_id" => ->(value) { value.is_a?(Integer) && value.positive? },
    "to_plan_price_id" => ->(value) { value.is_a?(Integer) && value.positive? },
    "plan_key" => ->(value) { value.to_s.match?(Plan::KEY_PATTERN) },
    "from_plan_key" => ->(value) { value.to_s.match?(Plan::KEY_PATTERN) },
    "to_plan_key" => ->(value) { value.to_s.match?(Plan::KEY_PATTERN) },
    "from_status" => ->(value) { value.nil? || Billing::Subscription.statuses.key?(value.to_s) },
    "to_status" => ->(value) { Billing::Subscription.statuses.key?(value.to_s) },
    "environment" => ->(value) { value.to_s.in?(Billing::Subscription.environments.keys) },
    "test_mode" => ->(value) { value.in?([ true, false ]) },
    "reason_code" => ->(value) { value.to_s.match?(REASON_CODE_PATTERN) },
    "webhook_event_id" => ->(value) { value.is_a?(Integer) && value.positive? },
    "source" => ->(value) { value == "organization_invitation" },
    "public_id" => ->(value) { value.to_s.match?(UUID_PATTERN) }
  }.freeze

  class << self
    def call(**arguments)
      new(**arguments).call
    end
  end

  def initialize(
    organization:,
    actor_user:,
    action:,
    subject:,
    request_id: Current.request_id,
    job_id: Current.job_id,
    metadata: {}
  )
    @organization = organization
    @actor_user = actor_user
    @action = action
    @subject = subject
    @request_id = request_id
    @job_id = job_id
    @metadata = metadata
  end

  def call
    validate_inputs!

    @organization.audit_events.create!(
      actor_user: @actor_user,
      action: @action,
      subject_type: @subject.class.base_class.name,
      subject_id: @subject.id,
      request_id: @request_id,
      job_id: @job_id,
      metadata: normalized_metadata,
      created_at: Time.current
    )
  end

  private
    def validate_inputs!
      raise ArgumentError, "organization must be persisted" unless @organization&.persisted?
      raise ArgumentError, "subject must be persisted" unless @subject&.persisted?
      raise ArgumentError, "metadata must be a hash" unless @metadata.is_a?(Hash)
      raise ArgumentError, "audit subject must belong to organization" unless subject_belongs_to_organization?

      invalid_metadata = normalized_metadata.any? do |key, value|
        validator = METADATA_VALIDATORS[key]
        key.match?(SENSITIVE_METADATA_KEY_PATTERN) || !validator&.call(value)
      end
      return unless invalid_metadata

      raise ArgumentError, "audit metadata is not allowlisted"
    end

    def normalized_metadata
      @normalized_metadata ||= @metadata.deep_stringify_keys
    end

    def subject_belongs_to_organization?
      if @subject.is_a?(Organization)
        @subject.id == @organization.id
      else
        @subject.respond_to?(:organization_id) &&
          @subject.organization_id == @organization.id
      end
    end
end
