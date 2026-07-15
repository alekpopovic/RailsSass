class Organizations::BillingController < Organizations::BaseController
  def show
    authorize Current.organization, :billing?
  end
end
