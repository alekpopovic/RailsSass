class Organizations::SettingsController < Organizations::BaseController
  def show
    authorize Current.organization, :settings?
  end

  def update
    authorize Current.organization, :update?
    Organizations::UpdateSettings.new(
      actor: Current.user,
      name: settings_params[:name]
    ).call

    redirect_to organization_settings_path(organization_slug: Current.organization.slug),
      status: :see_other,
      notice: "Organization settings updated."
  rescue ActiveRecord::RecordInvalid => error
    raise unless error.record.is_a?(Organization)

    render :show, status: :unprocessable_content
  end

  private
    def settings_params
      params.expect(organization: [ :name ])
    end
end
