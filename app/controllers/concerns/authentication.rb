require "uri"

module Authentication
  extend ActiveSupport::Concern

  SESSION_COOKIE = :session_token
  MAXIMUM_DESTINATION_BYTES = 2 * 1024

  included do
    before_action :require_authentication
    helper_method :authenticated?
  end

  class_methods do
    def allow_unauthenticated_access(**options)
      skip_before_action :require_authentication, **options
    end
  end

  private
    def authenticated?
      resume_session
      Current.user.present?
    end

    def require_authentication
      resume_session || request_authentication
    end

    def resume_session
      Current.session ||= find_session_by_cookie
    end

    def find_session_by_cookie
      raw_token = cookies.encrypted[SESSION_COOKIE]
      return if raw_token.blank?

      session_record = Session.includes(:user).find_by_token(raw_token)
      return clear_session_cookie unless session_record

      if session_record.expired? || !session_record.user.authentication_allowed?
        session_record.destroy!
        return clear_session_cookie
      end

      session_record
    end

    def request_authentication
      store_authentication_location
      redirect_to new_session_path
    end

    def store_authentication_location
      return unless request.get? || request.head?

      store_authentication_destination(request.fullpath)
    end

    def store_authentication_destination(destination)
      safe_destination = safe_internal_path(destination)
      session[:return_to_after_authenticating] = safe_destination if safe_destination
    end

    def after_authentication_path
      safe_internal_path(session.delete(:return_to_after_authenticating)) || root_path
    end

    def safe_internal_path(candidate)
      return unless candidate.is_a?(String)
      return if candidate.bytesize > MAXIMUM_DESTINATION_BYTES
      return unless candidate.start_with?("/") && !candidate.start_with?("//")

      decoded_candidate = URI::DEFAULT_PARSER.unescape(candidate)
      return if decoded_candidate.start_with?("//")
      return if decoded_candidate.include?("\\") || decoded_candidate.match?(/[\u0000-\u001f\u007f]/)

      uri = URI.parse(candidate)
      candidate if uri.scheme.nil? && uri.host.nil?
    rescue URI::InvalidURIError
      nil
    end

    def start_new_session_with(session_record, raw_token)
      resume_session
      Current.session&.destroy! unless Current.session == session_record
      Current.session = nil
      reset_session

      Current.session = session_record
      cookies.encrypted[SESSION_COOKIE] = {
        value: raw_token,
        expires: session_record.expires_at,
        httponly: true,
        same_site: :lax,
        secure: Rails.env.production?
      }
    end

    def terminate_session
      Current.session&.destroy!
      Current.session = nil
      clear_session_cookie
      reset_session
    end

    def clear_session_cookie
      cookies.delete(SESSION_COOKIE, same_site: :lax, secure: Rails.env.production?)
      nil
    end
end
