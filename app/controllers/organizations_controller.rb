class OrganizationsController < ApplicationController
  def new
    @organization = Organization.new
  end

  def create
    @organization = Organizations::Create.new(
      user: Current.user,
      name: organization_params[:name],
      slug: organization_params[:slug]
    ).call

    redirect_to root_path, notice: "Your organization has been created."
  rescue ActiveRecord::RecordInvalid => error
    raise unless error.record.is_a?(Organization)

    @organization = error.record
    render :new, status: :unprocessable_content
  rescue ActiveRecord::RecordNotUnique
    @organization = Organization.new(organization_params)
    @organization.errors.add(:slug, :taken)
    render :new, status: :unprocessable_content
  end

  private
    def organization_params
      params.expect(organization: %i[name slug])
    end
end
