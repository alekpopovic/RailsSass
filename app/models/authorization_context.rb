class AuthorizationContext
  attr_reader :user, :organization, :membership

  def initialize(user:, organization:, membership:)
    @user = user
    @organization = organization
    @membership = membership
    freeze
  end
end
