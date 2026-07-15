module TenantContext
  extend ActiveSupport::Concern

  included do
    around_action :with_tenant_context
    helper_method :organization_switcher_options
  end

  private
    def with_tenant_context
      establish_tenant_context
      yield
    ensure
      Current.organization = nil
      Current.membership = nil
    end

    def establish_tenant_context
      # The session value is navigation state only. Clear it first so a failed
      # lookup can never preserve a previously authorized tenant as authority.
      session.delete(:organization_id)

      locator = Current.user.organization_access_locators
        .joins(:organization)
        .includes(:organization)
        .find_by!(organizations: { slug: normalized_organization_slug })
      candidate = locator.organization
      raise ActiveRecord::RecordNotFound unless candidate.active?

      Current.organization = candidate
      Current.membership = Current.organization.organization_memberships.active.find_by!(
        id: locator.organization_membership_id,
        user_id: Current.user.id
      )
      session[:organization_id] = Current.organization.id
    end

    def normalized_organization_slug
      Organization.normalize_value_for(:slug, params[:organization_slug])
    end

    def organization_switcher_options
      @organization_switcher_options ||= Current.user.organization_access_locators
        .joins(:organization)
        .includes(:organization)
        .merge(Organization.active)
        .order("organizations.name", "organizations.id")
        .map(&:organization)
    end
end
