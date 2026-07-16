class Catalog::SeedLocalCatalog
  ADVISORY_LOCK_ID = 20_260_716_010_600

  PRODUCTS = [
    {
      key: "core",
      name: "Core",
      description: "Core product for local development and tests.",
      active: true
    },
    {
      key: "analytics",
      name: "Analytics",
      description: "Analytics product for local development and tests.",
      active: true
    },
    {
      key: "crm",
      name: "CRM",
      description: "CRM product for local development and tests.",
      active: true
    }
  ].freeze

  PLANS = [
    {
      key: "professional",
      name: "Professional",
      description: "Professional plan for local development and tests.",
      active: true,
      free: false,
      position: 20
    },
    {
      key: "starter",
      name: "Starter",
      description: "Starter plan for local development and tests.",
      active: true,
      free: true,
      position: 10
    }
  ].freeze

  PRODUCT_FEATURES = {
    "analytics" => [
      {
        key: "dashboards",
        name: "Dashboards",
        description: "View Analytics dashboards.",
        kind: "flag",
        active: true
      },
      {
        key: "custom_reports",
        name: "Custom reports",
        description: "Create and view custom Analytics reports.",
        kind: "flag",
        active: true
      },
      {
        key: "csv_export",
        name: "CSV export",
        description: "Export Analytics reports as CSV files.",
        kind: "flag",
        active: true
      },
      {
        key: "report_limit",
        name: "Report limit",
        description: "Maximum number of Analytics reports for an organization.",
        kind: "limit",
        active: true
      }
    ]
  }.freeze

  def call
    return false unless local_environment?

    ApplicationRecord.transaction do
      ApplicationRecord.connection.execute(
        "SELECT pg_advisory_xact_lock(#{ADVISORY_LOCK_ID})"
      )
      seed_records(Product, PRODUCTS)
      seed_records(Plan, PLANS)
      seed_product_features
    end

    true
  end

  private
    def local_environment?
      Rails.env.local?
    end

    def seed_records(model, definitions)
      definitions.each do |definition|
        record = model.find_or_initialize_by(key: definition.fetch(:key))
        record.assign_attributes(definition.except(:key))
        record.save!
      end
    end

    def seed_product_features
      PRODUCT_FEATURES.each do |product_key, definitions|
        product = Product.find_by!(key: product_key)

        definitions.each do |definition|
          feature = product.product_features.find_or_initialize_by(key: definition.fetch(:key))
          expected_kind = definition.fetch(:kind)
          if feature.persisted? && feature.kind != expected_kind
            feature.errors.add(:kind, "does not match the reviewed feature identity")
            raise ActiveRecord::RecordInvalid, feature
          end

          mutable_attributes = definition.except(:key, :kind)
          mutable_attributes[:kind] = expected_kind if feature.new_record?
          feature.assign_attributes(mutable_attributes)
          feature.save!
        end
      end
    end
end
