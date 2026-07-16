class Admin::PlanProductsController < Admin::BaseController
  before_action :set_plan
  before_action :require_active_plan!, only: %i[new create]
  before_action :set_plan_product, only: :show

  def index
    @plan_products = platform_scope(
      @plan.plan_products.includes(:product, :plan_feature_entitlements)
    )
      .joins(:product)
      .order("products.key")
  end

  def show
  end

  def new
    @plan_product = @plan.plan_products.new
    set_available_products
  end

  def create
    product = Product.where(active: true).find_by!(key: plan_product_params.fetch(:product_key))
    @plan_product = @plan.plan_products.new(product: product)
    persist_catalog(@plan_product, {})

    if @plan_product.errors.empty?
      redirect_to admin_plan_plan_product_path(@plan.key, product.key),
        notice: "Product added to plan."
    else
      set_available_products
      render :new, status: :unprocessable_entity
    end
  end

  private
    def set_plan
      @plan = Plan.find_by!(key: params[:plan_key])
    end

    def set_plan_product
      product = Product.find_by!(key: params[:product_key])
      @plan_product = @plan.plan_products.includes(:product).find_by!(product_id: product.id)
    end

    def set_available_products
      assigned_product_ids = @plan.plan_products.select(:product_id)
      @available_products = Product.where(active: true)
        .where.not(id: assigned_product_ids)
        .order(:key)
    end

    def plan_product_params
      params.expect(plan_product: [ :product_key ])
    end

    def require_active_plan!
      raise ActiveRecord::RecordNotFound unless @plan.active?
    end
end
