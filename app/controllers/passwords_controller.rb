class PasswordsController < ApplicationController
  GENERIC_REQUEST_NOTICE = "If an eligible account exists, password reset instructions will arrive shortly."
  INVALID_TOKEN_MESSAGE = "This password reset link is invalid or has expired."

  allow_unauthenticated_access
  before_action :set_user_by_token, only: %i[ edit update ]
  rate_limit to: 5, within: 15.minutes, only: :create, name: "password-reset-request",
    with: -> { redirect_to new_password_path, alert: "Please wait before trying again." }
  rate_limit to: 10, within: 15.minutes, only: :update, name: "password-reset-update",
    with: -> { redirect_to new_password_path, alert: INVALID_TOKEN_MESSAGE }

  def new
  end

  def create
    user = User.find_by(email_address: User.normalize_email(params[:email_address]))
    UserMailer.password_reset(user).deliver_later if user&.password_reset_allowed?

    redirect_to new_session_path, notice: GENERIC_REQUEST_NOTICE
  end

  def edit
    @token = params[:token]
  end

  def update
    @token = params[:token]

    if update_password_and_revoke_sessions
      redirect_to new_session_path, notice: "Your password has been reset."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private
    def set_user_by_token
      @user = User.find_by_password_reset_token(params[:token].to_s)
      redirect_to(new_password_path, alert: INVALID_TOKEN_MESSAGE) unless @user&.password_reset_allowed?
    end

    def password_params
      params.expect(user: %i[ password password_confirmation ])
    end

    def update_password_and_revoke_sessions
      User.transaction do
        next false unless @user.update(password_params)

        @user.sessions.delete_all
        true
      end
    end
end
