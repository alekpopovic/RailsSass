class Admin::PlanFeatureEntitlementsController < Admin::BaseController
  before_action :set_plan_product
  before_action :require_active_catalog_for_attachment!, only: %i[new create]
  before_action :set_entitlement, only: %i[show edit update]

  def index
    @entitlements = platform_scope(
      @plan_product.plan_feature_entitlements.includes(:product_feature)
    ).joins(:product_feature).order("product_features.key")
  end

  def show
  end

  def new
    @entitlement = @plan_product.plan_feature_entitlements.new(
      enabled: false,
      unlimited: false,
      settings: {}
    )
    set_available_features
  end

  def create
    feature_product_key, feature_key = entitlement_identity
    feature_product = Product.where(active: true).find_by!(key: feature_product_key)
    product_feature = feature_product.product_features.where(active: true).find_by!(key: feature_key)
    @entitlement = @plan_product.plan_feature_entitlements.new(product_feature: product_feature)
    persist_catalog(@entitlement, entitlement_value_params)

    if @entitlement.errors.empty?
      redirect_to entitlement_path(@entitlement), notice: "Feature entitlement created."
    else
      set_available_features
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    persist_catalog(@entitlement, entitlement_value_params)

    if @entitlement.errors.empty?
      redirect_to entitlement_path(@entitlement), notice: "Feature entitlement updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private
    def set_plan_product
      @plan = Plan.find_by!(key: params[:plan_key])
      @product = Product.find_by!(key: params[:product_key])
      @plan_product = @plan.plan_products.find_by!(product_id: @product.id)
    end

    def set_entitlement
      product_feature = @product.product_features.find_by!(key: params[:feature_key])
      @entitlement = @plan_product.plan_feature_entitlements
        .includes(:product_feature)
        .find_by!(product_feature_id: product_feature.id)
    end

    def set_available_features
      assigned_feature_ids = @plan_product.plan_feature_entitlements.select(:product_feature_id)
      @available_features = @product.product_features.includes(:product)
        .where(active: true)
        .where.not(id: assigned_feature_ids)
        .order(:key)
    end

    def require_active_catalog_for_attachment!
      raise ActiveRecord::RecordNotFound unless @plan.active? && @product.active?
    end

    def entitlement_identity
      identity = params.expect(plan_feature_entitlement: [ :feature_identity ])
        .fetch(:feature_identity)
        .to_s
      product_key, feature_key, extra = identity.split("/", 3)
      raise ActiveRecord::RecordNotFound if product_key.blank? || feature_key.blank? || extra

      [ product_key, feature_key ]
    end

    def entitlement_value_params
      params.expect(plan_feature_entitlement: %i[enabled limit_value unlimited])
    end

    def entitlement_path(entitlement)
      admin_plan_feature_entitlement_path(
        plan_key: @plan.key,
        product_key: @product.key,
        feature_key: entitlement.product_feature.key
      )
    end
end
