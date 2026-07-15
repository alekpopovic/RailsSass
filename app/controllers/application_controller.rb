class ApplicationController < ActionController::Base
  include Authentication
  include Pundit::Authorization

  rescue_from ActiveRecord::RecordNotFound, with: :render_not_found
  rescue_from Pundit::NotAuthorizedError, with: :render_forbidden

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  private
    def pundit_user
      AuthorizationContext.new(
        user: Current.user,
        organization: Current.organization,
        membership: Current.membership
      )
    end

    def render_not_found
      render_generic_error(:not_found, "404")
    end

    def render_forbidden
      render_generic_error(:forbidden, "403")
    end

    def render_generic_error(status, page)
      respond_to do |format|
        format.html do
          render file: Rails.public_path.join("#{page}.html"), layout: false, status: status
        end
        format.any { head status }
      end
    end
end
