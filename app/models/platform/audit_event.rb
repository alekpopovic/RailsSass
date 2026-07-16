module Platform
  class AuditEvent < ApplicationRecord
    ACTIONS = %w[catalog.created catalog.updated catalog.deactivated].freeze
    SUBJECT_TYPES = %w[
      Product ProductFeature Plan PlanProduct PlanFeatureEntitlement PlanPrice
    ].freeze
    CHANGE_SET_MAX_BYTES = 15_000

    belongs_to :actor_user,
      class_name: "User",
      inverse_of: :platform_audit_events_as_actor

    attr_readonly :actor_user_id,
      :action,
      :subject_type,
      :subject_id,
      :subject_key,
      :change_set,
      :occurred_at,
      :created_at

    validates :action, inclusion: { in: ACTIONS }
    validates :subject_type, inclusion: { in: SUBJECT_TYPES }
    validates :subject_id, numericality: { only_integer: true, greater_than: 0 }
    validates :subject_key,
      presence: true,
      length: { maximum: 255 },
      format: { with: /\A\S(?:.*\S)?\z/ }
    validates :occurred_at, presence: true
    validate :actor_is_an_active_platform_admin, on: :create
    validate :change_set_is_a_bounded_object

    def readonly?
      persisted? || super
    end

    private
      def actor_is_an_active_platform_admin
        return if actor_user&.platform_admin? && actor_user.authentication_allowed?

        errors.add(:actor_user, "must be an active platform administrator")
      end

      def change_set_is_a_bounded_object
        unless change_set.is_a?(Hash)
          errors.add(:change_set, "must be an object")
          return
        end

        if JSON.generate(change_set).bytesize > CHANGE_SET_MAX_BYTES
          errors.add(:change_set, "is too large")
        end
      end
  end
end
