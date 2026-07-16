class Admin::ProductFeaturesController < Admin::BaseController
  before_action :set_product
  before_action :set_product_feature, only: %i[show edit update]

  def index
    @product_features = platform_scope(@product.product_features).order(:key)
  end

  def show
  end

  def new
    @product_feature = @product.product_features.new(active: true, kind: :flag)
  end

  def create
    @product_feature = @product.product_features.new
    persist_catalog(@product_feature, product_feature_create_params)

    if @product_feature.errors.empty?
      redirect_to admin_product_feature_path(@product.key, @product_feature.key),
        notice: "Product feature created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    persist_catalog(@product_feature, product_feature_update_params)

    if @product_feature.errors.empty?
      redirect_to admin_product_feature_path(@product.key, @product_feature.key),
        notice: "Product feature updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private
    def set_product
      @product = Product.find_by!(key: params[:product_key])
    end

    def set_product_feature
      @product_feature = @product.product_features.find_by!(key: params[:key])
    end

    def product_feature_create_params
      params.expect(product_feature: %i[key name description kind active])
    end

    def product_feature_update_params
      params.expect(product_feature: %i[name description active])
    end
end
