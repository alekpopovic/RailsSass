class AnalyticsReport < ApplicationRecord
  NAME_MAX_LENGTH = 100
  DESCRIPTION_MAX_LENGTH = 2_000

  belongs_to :organization, inverse_of: :analytics_reports

  normalizes :name, with: ->(name) { name.to_s.strip }
  normalizes :description,
    with: ->(description) { description.to_s.strip },
    apply_to_nil: true

  attr_readonly :organization_id, :public_id

  validates :name, presence: true, length: { maximum: NAME_MAX_LENGTH }
  validates :description, length: { maximum: DESCRIPTION_MAX_LENGTH }
end
