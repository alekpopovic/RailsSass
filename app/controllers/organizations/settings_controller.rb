class Organizations::SettingsController < Organizations::BaseController
  def show
    authorize Current.organization, :settings?
  end
end
