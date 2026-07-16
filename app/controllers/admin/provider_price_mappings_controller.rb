class Admin::ProviderPriceMappingsController < Admin::BaseController
  skip_after_action :verify_policy_scoped

  before_action :set_plan_and_price
  before_action :set_mapping, only: %i[edit update]

  def new
    @mapping = @plan_price.billing_provider_price_mappings.new(
      provider: "lemon_squeezy",
      environment: available_environments.first || "test",
      active: true
    )
  end

  def create
    @mapping = configure_mapping(
      environment: mapping_params[:environment],
      active: mapping_params[:active]
    )
    redirect_to admin_plan_plan_price_path(@plan.key, @plan_price),
      notice: "Provider mapping configured."
  rescue ActiveRecord::RecordInvalid => error
    @mapping = error.record
    render :new, status: :unprocessable_content
  end

  def edit
  end

  def update
    @mapping = configure_mapping(
      environment: @mapping.environment,
      active: mapping_params[:active]
    )
    redirect_to admin_plan_plan_price_path(@plan.key, @plan_price),
      notice: "Provider mapping updated."
  rescue ActiveRecord::RecordInvalid => error
    @mapping = error.record
    render :edit, status: :unprocessable_content
  end

  private
    def set_plan_and_price
      @plan = Plan.find_by!(key: params[:plan_key])
      @plan_price = @plan.plan_prices.find(params[:plan_price_id])
    end

    def set_mapping
      @mapping = @plan_price.billing_provider_price_mappings.find_by!(
        provider: "lemon_squeezy",
        environment: params[:environment]
      )
    end

    def mapping_params
      params.expect(billing_provider_price_mapping: %i[environment active])
    end

    def configure_mapping(environment:, active:)
      Platform::ConfigureProviderPriceMapping.new(
        actor: Current.user,
        plan_price: @plan_price,
        environment: environment,
        active: active
      ).call
    end

    def available_environments
      Billing::ProviderPriceMapping.environments.keys -
        @plan_price.billing_provider_price_mappings.pluck(:environment)
    end
end
