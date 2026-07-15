class SessionsController < ApplicationController
  INVALID_CREDENTIALS_MESSAGE = "Invalid email or password."

  allow_unauthenticated_access only: %i[ new create ]
  rate_limit to: 10, within: 3.minutes, only: :create,
    with: -> { redirect_to new_session_path, alert: INVALID_CREDENTIALS_MESSAGE }

  def new
  end

  def create
    user = User.authenticate_by(
      email_address: User.normalize_email(params[:email_address]),
      password: params[:password]
    )

    if user&.authentication_allowed?
      destination = after_authentication_path
      start_new_session_for(user)
      redirect_to destination, allow_other_host: false
    else
      redirect_to new_session_path, alert: INVALID_CREDENTIALS_MESSAGE
    end
  end

  def destroy
    terminate_session
    redirect_to new_session_path, status: :see_other, notice: "You have been signed out."
  end
end
