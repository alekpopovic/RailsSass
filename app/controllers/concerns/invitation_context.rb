module InvitationContext
  extend ActiveSupport::Concern

  included do
    around_action :with_invitation_context
  end

  private
    def with_invitation_context
      Current.organization = Organization.active.find_by!(slug: normalized_invitation_organization_slug)
      Current.membership = nil
      yield
    ensure
      Current.organization = nil
      Current.membership = nil
    end

    def normalized_invitation_organization_slug
      Organization.normalize_value_for(:slug, params[:organization_slug])
    end
end
