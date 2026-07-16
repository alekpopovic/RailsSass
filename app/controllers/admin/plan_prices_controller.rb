class Admin::PlanPricesController < Admin::BaseController
  before_action :set_plan
  before_action :require_active_plan!, only: %i[new create]
  before_action :set_plan_price, only: %i[show edit update]

  def index
    @plan_prices = platform_scope(@plan.plan_prices)
      .includes(:billing_provider_price_mappings)
      .order(:billing_interval, :currency, :amount_cents)
  end

  def show
    @provider_price_mappings = @plan_price.billing_provider_price_mappings.order(:environment)
  end

  def new
    @plan_price = @plan.plan_prices.new(active: true, currency: "EUR")
    @plan_price_referenced = false
  end

  def create
    @plan_price = @plan.plan_prices.new
    persist_catalog(@plan_price, plan_price_params)

    if @plan_price.errors.empty?
      redirect_to admin_plan_plan_price_path(@plan.key, @plan_price), notice: "Plan price created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    persist_catalog(@plan_price, plan_price_params)

    if @plan_price.errors.empty?
      redirect_to admin_plan_plan_price_path(@plan.key, @plan_price), notice: "Plan price updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private
    def set_plan
      @plan = Plan.find_by!(key: params[:plan_key])
    end

    def set_plan_price
      @plan_price = @plan.plan_prices.find(params[:id])
      @plan_price_referenced = Platform::PersistCatalog.plan_price_referenced?(@plan_price)
    end

    def plan_price_params
      params.expect(
        plan_price: %i[
          billing_interval currency amount_cents lemon_store_id lemon_product_id
          lemon_variant_id active
        ]
      )
    end

    def require_active_plan!
      raise ActiveRecord::RecordNotFound unless @plan.active?
    end
end
