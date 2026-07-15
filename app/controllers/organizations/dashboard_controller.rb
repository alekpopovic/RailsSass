class Organizations::DashboardController < Organizations::BaseController
  def show
    authorize Current.organization, :dashboard?
  end
end
