require "test_helper"

class HomePageRequestTest < ActionDispatch::IntegrationTest
  test "renders the application foundation" do
    get root_path

    assert_response :success
    assert_select "html[lang='en']"
    assert_select "title", "RailsSass foundation"
    assert_select "h1", "RailsSass foundation"
    assert_select "main#main-content"
    assert_select "a[href='#main-content']", "Skip to main content"
  end
end
