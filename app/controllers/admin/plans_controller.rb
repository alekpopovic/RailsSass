class Admin::PlansController < Admin::BaseController
  before_action :set_plan, only: %i[show edit update]

  def index
    @plans = platform_scope(Plan).order(:position, :key)
  end

  def show
  end

  def new
    @plan = Plan.new(active: true, free: false, position: 0)
  end

  def create
    @plan = Plan.new
    persist_catalog(@plan, plan_create_params)

    if @plan.errors.empty?
      redirect_to admin_plan_path(@plan.key), notice: "Plan created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    persist_catalog(@plan, plan_update_params)

    if @plan.errors.empty?
      redirect_to admin_plan_path(@plan.key), notice: "Plan updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private
    def set_plan
      @plan = Plan.find_by!(key: params[:key])
    end

    def plan_create_params
      params.expect(plan: %i[key name description active free position])
    end

    def plan_update_params
      params.expect(plan: %i[name description active free position])
    end
end
