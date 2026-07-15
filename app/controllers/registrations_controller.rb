class RegistrationsController < ApplicationController
  GENERIC_NOTICE = "If your registration can be completed, verification instructions will arrive shortly."

  allow_unauthenticated_access
  rate_limit to: 5, within: 10.minutes, only: :create,
    with: -> { redirect_to new_registration_path, alert: "Please wait before trying again." }

  def new
    @user = User.new
  end

  def create
    @user = User.new(registration_params)

    if @user.save
      UserMailer.email_verification(@user).deliver_later
      redirect_after_registration
    else
      handle_registration_errors
    end
  rescue ActiveRecord::RecordNotUnique
    redirect_after_registration
  end

  private
    def registration_params
      params.expect(user: %i[ name email_address password password_confirmation ])
    end

    def handle_registration_errors
      duplicate_email = @user.errors.of_kind?(:email_address, :taken)
      @user.errors.delete(:email_address, :taken)

      if duplicate_email && @user.errors.empty?
        redirect_after_registration
      else
        render :new, status: :unprocessable_entity
      end
    end

    def redirect_after_registration
      redirect_to new_session_path, notice: GENERIC_NOTICE
    end
end
