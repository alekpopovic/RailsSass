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

  def call
    return false unless local_environment?

    ApplicationRecord.transaction do
      ApplicationRecord.connection.execute(
        "SELECT pg_advisory_xact_lock(#{ADVISORY_LOCK_ID})"
      )
      seed_records(Product, PRODUCTS)
      seed_records(Plan, PLANS)
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
end
