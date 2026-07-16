class Organizations::ProductsController < Organizations::BaseController
  def index
    authorize Current.organization, :products?
    @product_cards = CustomerShell::ProductCatalog.new(
      context: pundit_user
    ).call
  end
end
