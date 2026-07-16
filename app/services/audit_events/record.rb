class AuditEvents::Record
  SENSITIVE_METADATA_KEY_PATTERN = /(?:email|token)/i
  UUID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i
  METADATA_VALIDATORS = {
    "organization_role" => ->(value) { OrganizationMembership.roles.key?(value.to_s) },
    "from_role" => ->(value) { OrganizationMembership.roles.key?(value.to_s) },
    "to_role" => ->(value) { OrganizationMembership.roles.key?(value.to_s) },
    "membership_id" => ->(value) { value.is_a?(Integer) && value.positive? },
    "product_key" => ->(value) { value.to_s.match?(Product::KEY_PATTERN) },
    "product_role_key" => ->(value) { value.to_s.match?(ProductRole::KEY_PATTERN) },
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
    request_id: nil,
    job_id: nil,
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
      occurred_at: Time.current
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
