class Admin::Billing::SubscriptionsController < Admin::BaseController
  def index
    @organization = selected_organization(platform_scope(Organization))
    @subscriptions_page = subscriptions_for(@organization)
  end

  def show
    @organization = Organization.find_by!(public_id: params[:organization_public_id])
    @subscription = Current.set(organization: @organization) do
      Current.organization.billing_subscriptions
        .includes(plan_price: :plan)
        .find(params[:id])
    end
  end

  private
    def selected_organization(organizations)
      public_id = params[:organization_public_id].presence
      organizations.find_by!(public_id: public_id) if public_id
    end

    def subscriptions_for(organization)
      return empty_admin_page unless organization

      Current.set(organization: organization) do
        paginate_admin(
          Current.organization.billing_subscriptions
            .includes(plan_price: :plan)
            .order(updated_at: :desc, id: :desc)
        )
      end
    end
end
