class Organizations::InvitationAcceptancesController < ApplicationController
  include InvitationContext

  AUTHENTICATION_NOTICE = "Sign in or register, then reopen the invitation link from your email."

  prepend_before_action :set_sensitive_response_headers
  after_action :verify_authorized
  rate_limit to: 10, within: 15.minutes, only: :update, name: "organization-invitation-accept",
    by: -> { "#{Current.user.id}:#{Current.organization.id}" },
    with: -> { raise ActiveRecord::RecordNotFound }
  before_action :set_invitation

  def show
    authorize_acceptance!
  end

  def update
    authorize_acceptance!
    Organizations::Invitations::Accept.new(
      user: Current.user,
      raw_token: @raw_token
    ).call

    redirect_to organization_dashboard_path(organization_slug: Current.organization.slug),
      status: :see_other,
      notice: "Invitation accepted."
  end

  private
    def request_authentication
      redirect_to new_session_path, alert: AUTHENTICATION_NOTICE
    end

    def set_sensitive_response_headers
      response.headers["Cache-Control"] = "no-store"
      response.headers["Referrer-Policy"] = "no-referrer"
    end

    def set_invitation
      @raw_token = params[:token].to_s
      @invitation = Organizations::Invitations::Lookup.new(
        user: Current.user,
        raw_token: @raw_token
      ).call
    end

    def authorize_acceptance!
      authorize @invitation, :accept?
    rescue Pundit::NotAuthorizedError
      raise ActiveRecord::RecordNotFound
    end
end
