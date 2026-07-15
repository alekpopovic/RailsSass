class AuditEvent < ApplicationRecord
  ACTION_PATTERN = /\A[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)+\z/
  ACTION_MAX_LENGTH = 100
  SUBJECT_TYPE_MAX_LENGTH = 100
  CORRELATION_ID_MAX_LENGTH = 255

  belongs_to :organization, inverse_of: :audit_events
  belongs_to :actor_user,
    class_name: "User",
    inverse_of: :audit_events_as_actor,
    optional: true

  validates :action,
    presence: true,
    length: { maximum: ACTION_MAX_LENGTH },
    format: { with: ACTION_PATTERN }
  validates :subject_type,
    presence: true,
    length: { maximum: SUBJECT_TYPE_MAX_LENGTH }
  validates :subject_id, numericality: { only_integer: true, greater_than: 0 }
  validates :request_id, :job_id,
    length: { maximum: CORRELATION_ID_MAX_LENGTH },
    allow_nil: true
  validates :occurred_at, presence: true
  validate :metadata_is_an_object

  def readonly?
    persisted? || super
  end

  private
    def metadata_is_an_object
      errors.add(:metadata, "must be an object") unless metadata.is_a?(Hash)
    end
end
