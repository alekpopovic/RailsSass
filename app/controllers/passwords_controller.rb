class PasswordsController < ApplicationController
  GENERIC_REQUEST_NOTICE = "If an eligible account exists, password reset instructions will arrive shortly."
  INVALID_TOKEN_MESSAGE = "This password reset link is invalid or has expired."

  allow_unauthenticated_access
  rate_limit to: 5, within: 15.minutes, only: :create, name: "password-reset-request",
    with: -> { redirect_to new_password_path, alert: "Please wait before trying again." }
  rate_limit to: 10, within: 15.minutes, only: :update, name: "password-reset-update",
    with: -> { redirect_to new_password_path, alert: INVALID_TOKEN_MESSAGE }
  prepend_before_action :set_sensitive_response_headers, only: %i[edit update]
  before_action :set_user_by_token, only: :edit

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
    result = Accounts::ResetPassword.new(
      raw_token: @token,
      attributes: password_params
    ).call

    if result.updated?
      redirect_to new_session_path, notice: "Your password has been reset."
    elsif result.invalid_token?
      redirect_to new_password_path, alert: INVALID_TOKEN_MESSAGE
    else
      @user = result.user
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

    def set_sensitive_response_headers
      response.headers["Cache-Control"] = "no-store"
      response.headers["Referrer-Policy"] = "no-referrer"
    end
end
