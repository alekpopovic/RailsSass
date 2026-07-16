class ProfilesController < ApplicationController
  after_action :verify_authorized

  def show
    @user = current_user
    authorize @user
  end

  def update
    @user = current_user
    authorize @user
    @user.update!(profile_params)

    redirect_to profile_path, status: :see_other, notice: "Profile updated."
  rescue ActiveRecord::RecordInvalid
    render :show, status: :unprocessable_content
  end

  private
    def current_user
      User.find(Current.user.id)
    end

    def profile_params
      params.expect(user: [ :name ])
    end
end
