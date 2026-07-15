require "application_system_test_case"

class HomePageSystemTest < ApplicationSystemTestCase
  test "visiting the foundation home page" do
    visit root_url

    assert_title "RailsSass foundation"
    assert_selector "h1", text: "RailsSass foundation"
    assert_text "The application foundation is ready"
  end
end
