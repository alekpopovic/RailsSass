require "test_helper"

class FlashPartialTest < ActionView::TestCase
  test "renders accessible escaped notices and alerts" do
    render partial: "shared/flash", locals: {
      flashes: { notice: "Settings saved", alert: "<script>Denied</script>" }
    }

    assert_select "section[aria-label='Notifications']"
    assert_select "[role='status']", text: "Settings saved"
    assert_select "[role='alert']", text: "<script>Denied</script>"
    assert_select "script", count: 0
  end

  test "omits empty flash messages" do
    render partial: "shared/flash", locals: { flashes: { notice: "" } }

    assert_select "section", count: 0
  end
end
