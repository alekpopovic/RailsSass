class Admin::ProductsController < Admin::BaseController
  before_action :set_product, only: %i[show edit update]

  def index
    @products = platform_scope(Product).order(:key)
  end

  def show
  end

  def new
    @product = Product.new(active: true)
  end

  def create
    @product = Product.new
    persist_catalog(@product, product_create_params)

    if @product.errors.empty?
      redirect_to admin_product_path(@product.key), notice: "Product created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    persist_catalog(@product, product_update_params)

    if @product.errors.empty?
      redirect_to admin_product_path(@product.key), notice: "Product updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private
    def set_product
      @product = Product.find_by!(key: params[:key])
    end

    def product_create_params
      params.expect(product: %i[key name description active])
    end

    def product_update_params
      params.expect(product: %i[name description active])
    end
end
