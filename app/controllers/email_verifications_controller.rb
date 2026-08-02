class EmailVerificationsController < ApplicationController
  GENERIC_REQUEST_NOTICE = "If an eligible account exists, verification instructions will arrive shortly."
  INVALID_TOKEN_MESSAGE = "This email verification link is invalid or has expired."

  allow_unauthenticated_access
  rate_limit to: 5, within: 15.minutes, only: :create, name: "email-verification-request",
    with: -> { redirect_to new_email_verification_path, alert: "Please wait before trying again." }
  rate_limit to: 10, within: 15.minutes, only: :update, name: "email-verification-update",
    with: -> { redirect_to new_session_path, alert: INVALID_TOKEN_MESSAGE }
  prepend_before_action :set_sensitive_response_headers, only: %i[edit update]
  before_action :set_user_by_token, only: :edit

  def new
  end

  def create
    user = User.find_by(email_address: User.normalize_email(params[:email_address]))
    UserMailer.email_verification(user).deliver_later if user&.email_verification_allowed?

    redirect_to new_session_path, notice: GENERIC_REQUEST_NOTICE
  end

  def edit
    @token = params[:token]
  end

  def update
    result = Accounts::VerifyEmail.new(raw_token: params[:token]).call
    unless result.verified?
      redirect_to new_session_path, alert: INVALID_TOKEN_MESSAGE
      return
    end

    unless safe_internal_path(session[:return_to_after_authenticating])
      store_authentication_destination(new_organization_path)
    end
    redirect_to new_session_path, notice: "Your email address has been verified. You can now sign in."
  end

  private
    def set_user_by_token
      @user = User.find_by_email_verification_token(params[:token].to_s)
      redirect_to(new_session_path, alert: INVALID_TOKEN_MESSAGE) unless @user&.email_verification_allowed?
    end

    def set_sensitive_response_headers
      response.headers["Cache-Control"] = "no-store"
      response.headers["Referrer-Policy"] = "no-referrer"
    end
end
