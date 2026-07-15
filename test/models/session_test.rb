require "test_helper"

class SessionTest < ActiveSupport::TestCase
  PASSWORD = "correct horse battery staple"

  setup do
    @user = User.create!(
      name: "Session User",
      email_address: "session-user@example.test",
      password: PASSWORD,
      password_confirmation: PASSWORD,
      email_verified_at: Time.current
    )
  end

  test "issues a digest-backed session and finds it only by the raw token" do
    session, raw_token = Session.issue_for!(
      @user,
      ip_address: "203.0.113.10",
      user_agent: "Browser/1.0"
    )

    assert_predicate session, :persisted?
    assert_equal @user, session.user
    assert_equal "203.0.113.10", session.ip_address.to_s
    assert_equal "Browser/1.0", session.user_agent
    assert_equal Digest::SHA256.hexdigest(raw_token), session.token_digest
    assert_not_equal raw_token, session.token_digest
    assert_not_includes session.attributes.values.map(&:to_s), raw_token
    assert_not_includes Session.column_names, "token"
    assert_equal session, Session.find_by_token(raw_token)
    assert_nil Session.find_by_token("incorrect-token")
    assert_nil Session.find_by_token(nil)
  end

  test "sets a bounded expiry and excludes expired sessions from the active scope" do
    session, = Session.issue_for!(@user, ip_address: nil, user_agent: nil)

    assert_in_delta Session::LIFETIME.from_now, session.expires_at, 1.second
    assert_not session.expired?
    assert_includes Session.active, session

    travel Session::LIFETIME + 1.second do
      assert_predicate session, :expired?
      assert_not_includes Session.active, session
    end
  end

  test "bounds the persisted user agent" do
    session, = Session.issue_for!(
      @user,
      ip_address: nil,
      user_agent: "x" * (Session::USER_AGENT_MAX_LENGTH + 50)
    )

    assert_equal Session::USER_AGENT_MAX_LENGTH, session.user_agent.length
  end

  test "validates token digest format and expiry order" do
    session = @user.sessions.build(
      token_digest: "raw-token",
      created_at: Time.current,
      expires_at: 1.second.ago
    )

    assert_not session.valid?
    assert session.errors.of_kind?(:token_digest, :wrong_length)
    assert session.errors.of_kind?(:token_digest, :invalid)
    assert session.errors.of_kind?(:expires_at, :greater_than)
  end

  test "database cascades sessions when their user is deleted directly" do
    session, = Session.issue_for!(@user, ip_address: nil, user_agent: nil)

    User.where(id: @user.id).delete_all

    assert_not Session.exists?(session.id)
  end
end
