class Organizations::BaseController < ApplicationController
  include TenantContext

  after_action :verify_authorized
end
