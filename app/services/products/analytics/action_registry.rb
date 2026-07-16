module Products
  module Analytics
    class ActionRegistry
      PRODUCT_KEY = "analytics"

      FeatureRequirement = Data.define(:key, :kind) do
        KINDS = %i[flag limit].freeze

        def initialize(key:, kind:)
          normalized_key = key.to_s
          normalized_kind = kind.to_sym
          raise ArgumentError, "feature key is required" if normalized_key.blank?
          raise ArgumentError, "invalid feature kind" unless KINDS.include?(normalized_kind)

          super(key: normalized_key.freeze, kind: normalized_kind)
        end
      end

      Action = Data.define(
        :permission_key,
        :feature_requirements,
        :capacity_feature_key,
        :capacity_delta
      ) do
        def initialize(
          permission_key:,
          feature_requirements:,
          capacity_feature_key: nil,
          capacity_delta: 0
        )
          normalized_permission_key = permission_key.to_s
          normalized_requirements = Array(feature_requirements).dup.freeze
          normalized_capacity_feature_key = capacity_feature_key&.to_s

          raise ArgumentError, "permission key is required" if normalized_permission_key.blank?
          unless normalized_requirements.all?(FeatureRequirement)
            raise ArgumentError, "invalid feature requirement"
          end
          unless capacity_delta.is_a?(Integer) && capacity_delta >= 0
            raise ArgumentError, "capacity delta must be a non-negative integer"
          end
          if capacity_delta.positive? && normalized_capacity_feature_key.blank?
            raise ArgumentError, "a consuming action requires a capacity feature"
          end
          unless normalized_capacity_feature_key.nil? || normalized_requirements.any? { |requirement|
            requirement.key == normalized_capacity_feature_key && requirement.kind == :limit
          }
            raise ArgumentError, "capacity feature must be a registered limit requirement"
          end

          super(
            permission_key: normalized_permission_key.freeze,
            feature_requirements: normalized_requirements,
            capacity_feature_key: normalized_capacity_feature_key&.freeze,
            capacity_delta: capacity_delta
          )
        end

        def consuming?
          capacity_delta.positive?
        end
      end

      class Decision
        attr_reader :action, :requirements_and_decisions

        def initialize(action:, requirements_and_decisions:)
          @action = action
          @requirements_and_decisions = requirements_and_decisions.dup.freeze
          freeze
        end

        def allowed?
          failure.nil?
        end

        def denied?
          !allowed?
        end

        def reason_code
          return :access_granted if allowed?

          requirement, access_decision = failure
          return access_decision.reason_code if access_decision.denied?
          return :feature_kind_mismatch unless access_decision.feature_kind == requirement.kind

          :invalid_limit_configuration
        end

        def message
          return if allowed?

          access_decision = failure.last
          access_decision.denied? ? access_decision.message : Access::Gate::FEATURE_PLAN_MESSAGE
        end

        def capacity
          return unless action.consuming?

          capacity_decision&.capacity
        end

        def capacity_delta
          action.capacity_delta
        end

        def access_decision
          return requirements_and_decisions.last&.last if allowed?

          failure.last
        end

        private
          def failure
            requirements_and_decisions.find do |requirement, access_decision|
              access_decision.denied? ||
                access_decision.feature_kind != requirement.kind ||
                invalid_capacity?(requirement, access_decision)
            end
          end

          def invalid_capacity?(requirement, access_decision)
            return false unless requirement.kind == :limit

            capacity = access_decision.capacity
            capacity != Access::Decision::UNLIMITED &&
              !(capacity.is_a?(Integer) && capacity >= 0)
          end

          def capacity_decision
            requirements_and_decisions.find { |requirement, _decision|
              requirement.key == action.capacity_feature_key
            }&.last
          end
      end

      ACTIONS = {
        dashboard_read: Action.new(
          permission_key: "analytics.dashboard.read",
          feature_requirements: [ FeatureRequirement.new(key: "dashboards", kind: :flag) ]
        ),
        report_read: Action.new(
          permission_key: "analytics.report.read",
          feature_requirements: [ FeatureRequirement.new(key: "custom_reports", kind: :flag) ]
        ),
        report_create: Action.new(
          permission_key: "analytics.report.create",
          feature_requirements: [
            FeatureRequirement.new(key: "custom_reports", kind: :flag),
            FeatureRequirement.new(key: "report_limit", kind: :limit)
          ],
          capacity_feature_key: "report_limit",
          capacity_delta: 1
        ),
        report_manage: Action.new(
          permission_key: "analytics.report.manage",
          feature_requirements: [ FeatureRequirement.new(key: "custom_reports", kind: :flag) ]
        ),
        export_run: Action.new(
          permission_key: "analytics.export.run",
          feature_requirements: [ FeatureRequirement.new(key: "csv_export", kind: :flag) ]
        )
      }.freeze

      class << self
        def decision(action_name, context:, now: Time.current)
          action = ACTIONS.fetch(normalized_action_name(action_name))
          requirements_and_decisions = action.feature_requirements.map do |requirement|
            access_decision = Access::Gate.new(
              context: context,
              product_key: PRODUCT_KEY,
              permission_key: action.permission_key,
              feature_key: requirement.key,
              now: now
            ).call
            [ requirement, access_decision ].freeze
          end

          Decision.new(action: action, requirements_and_decisions: requirements_and_decisions)
        end

        private
          def normalized_action_name(action_name)
            action_name.to_sym
          rescue NoMethodError
            raise KeyError, "unknown Analytics action"
          end
      end
    end
  end
end
