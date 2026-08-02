require "digest"

module Platform
  class PersistCatalog
    Configuration = Data.define(:create_attributes, :update_attributes, :subject_key)

    CONFIGURATIONS = {
      "Product" => Configuration.new(
        create_attributes: %w[key name description active],
        update_attributes: %w[name description active],
        subject_key: ->(record) { record.key }
      ),
      "ProductFeature" => Configuration.new(
        create_attributes: %w[key name description kind active],
        update_attributes: %w[name description active],
        subject_key: ->(record) { "#{record.product.key}/#{record.key}" }
      ),
      "Plan" => Configuration.new(
        create_attributes: %w[key name description active free position],
        update_attributes: %w[name description active free position],
        subject_key: ->(record) { record.key }
      ),
      "PlanProduct" => Configuration.new(
        create_attributes: [],
        update_attributes: [],
        subject_key: ->(record) { "#{record.plan.key}/#{record.product.key}" }
      ),
      "PlanFeatureEntitlement" => Configuration.new(
        create_attributes: %w[enabled limit_value unlimited settings],
        update_attributes: %w[enabled limit_value unlimited settings],
        subject_key: lambda do |record|
          plan_product = record.plan_product
          "#{plan_product.plan.key}/#{plan_product.product.key}/#{record.product_feature.key}"
        end
      ),
      "PlanPrice" => Configuration.new(
        create_attributes: %w[
          billing_interval currency amount_cents lemon_store_id lemon_product_id
          lemon_variant_id active
        ],
        update_attributes: %w[
          billing_interval currency amount_cents lemon_store_id lemon_product_id
          lemon_variant_id active
        ],
        subject_key: ->(record) { "#{record.plan.key}/price/#{record.id}" }
      )
    }.freeze

    IDENTITY_ATTRIBUTES = %w[
      key product product_id kind plan plan_id plan_product plan_product_id
      product_feature product_feature_id feature_kind
    ].freeze
    IDENTITY_ASSOCIATIONS = {
      "Product" => [],
      "ProductFeature" => %i[product],
      "Plan" => [],
      "PlanProduct" => %i[plan product],
      "PlanFeatureEntitlement" => %i[plan_product product_feature],
      "PlanPrice" => %i[plan]
    }.freeze
    SENSITIVE_VALUE_ATTRIBUTES = %w[settings].freeze
    PLAN_PRICE_REFERENCE_ASSOCIATIONS = %i[
      billing_provider_price_mappings billing_checkout_attempts billing_subscriptions
      billing_plan_changes_from billing_plan_changes_to
    ].freeze

    class << self
      def plan_price_referenced?(record)
        return false unless record.is_a?(PlanPrice) && record.persisted?

        PLAN_PRICE_REFERENCE_ASSOCIATIONS.any? do |association|
          record.public_send(association).exists?
        end
      end
    end

    def initialize(actor:, record:, attributes:)
      @actor = actor
      @record = record
      @attributes = attributes
    end

    def call
      configuration = configuration_for_record!
      return record unless actor_reference_is_valid?
      return record unless identity_associations_are_persisted?

      normalized_attributes = normalize_attributes!
      was_new_record = record.new_record?

      ApplicationRecord.transaction do
        authoritative_actor = lock_authorized_actor
        next unless authoritative_actor

        record.lock! unless was_new_record
        allowed_attributes = attributes_allowed_for(configuration)
        next unless permitted_attributes?(normalized_attributes, allowed_attributes)

        was_active = record.respond_to?(:active?) && record.active?
        record.assign_attributes(normalized_attributes)
        next unless record.save

        changes = audited_changes(record.saved_changes, allowed_attributes)
        next if !was_new_record && changes.empty?

        AuditEvent.create!(
          actor_user: authoritative_actor,
          action: audit_action(was_new_record:, was_active:),
          subject_type: record.class.name,
          subject_id: record.id,
          subject_key: configuration.subject_key.call(record),
          change_set: changes,
          occurred_at: Time.current
        )
      end

      record
    rescue ActiveRecord::RecordNotUnique
      record.errors.add(:base, "conflicts with an existing catalog record")
      record
    end

    private
      attr_reader :actor, :record, :attributes

      def configuration_for_record!
        CONFIGURATIONS.fetch(record.class.name)
      rescue KeyError
        raise ArgumentError, "unsupported catalog record"
      end

      def actor_reference_is_valid?
        return true if actor.is_a?(User) && actor.persisted?

        record.errors.add(:base, "platform administrator is required")
        false
      end

      def identity_associations_are_persisted?
        associations = IDENTITY_ASSOCIATIONS.fetch(record.class.name)
        return true if associations.all? { |association| record.public_send(association)&.persisted? }

        record.errors.add(:base, "catalog relationships must already exist")
        false
      end

      def lock_authorized_actor
        authoritative_actor = User.lock.find_by(id: actor.id)
        if authoritative_actor&.platform_admin? &&
            authoritative_actor.authentication_allowed? &&
            Current.user&.id == authoritative_actor.id &&
            AuthorizationContext.current.authenticated?
          return authoritative_actor
        end

        record.errors.add(:base, "platform administrator is required")
        nil
      end

      def normalize_attributes!
        unless attributes.respond_to?(:to_h)
          raise ArgumentError, "attributes must be a hash"
        end

        attributes.to_h.stringify_keys
      end

      def attributes_allowed_for(configuration)
        return configuration.create_attributes if record.new_record?
        return configuration.update_attributes unless self.class.plan_price_referenced?(record)

        @referenced_plan_price = true
        %w[active]
      end

      def permitted_attributes?(normalized_attributes, allowed_attributes)
        disallowed_attributes = normalized_attributes.keys - allowed_attributes
        disallowed_attributes.each do |attribute|
          message = IDENTITY_ATTRIBUTES.include?(attribute) ? "cannot be changed" : "is not permitted"
          record.errors.add(attribute, message)
        end
        if @referenced_plan_price && disallowed_attributes.any?
          record.errors.add(:base, "Billing history exists; only active status can be changed")
        end

        disallowed_attributes.empty?
      end

      def audited_changes(saved_changes, allowed_attributes)
        saved_changes.slice(*allowed_attributes).to_h do |attribute, (before, after)|
          [ attribute, audited_values(attribute, before, after) ]
        end
      end

      def audited_values(attribute, before, after)
        if SENSITIVE_VALUE_ATTRIBUTES.include?(attribute)
          {
            "from" => fingerprint(before),
            "to" => fingerprint(after),
            "values_redacted" => true
          }
        else
          { "from" => before, "to" => after }
        end
      end

      def fingerprint(value)
        serialized = JSON.generate(value)
        {
          "sha256" => Digest::SHA256.hexdigest(serialized),
          "bytes" => serialized.bytesize
        }
      end

      def audit_action(was_new_record:, was_active:)
        if was_new_record
          "catalog.created"
        elsif was_active && record.respond_to?(:active?) && !record.active?
          "catalog.deactivated"
        else
          "catalog.updated"
        end
      end
  end
end
