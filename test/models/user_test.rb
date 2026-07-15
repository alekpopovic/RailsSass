require "test_helper"

class UserTest < ActiveSupport::TestCase
  PASSWORD = "correct horse battery staple"

  test "normalizes account attributes and defaults to the user system role" do
    user = build_user(name: "  Example User  ", email_address: "  PERSON@Example.TEST  ")

    assert user.save
    assert_equal "Example User", user.name
    assert_equal "person@example.test", user.email_address
    assert_equal "user", user.system_role
    assert_predicate user, :user?
  end

  test "authenticates a sufficiently long password and rejects shorter passwords" do
    user = create_user!

    assert_equal user, user.authenticate(PASSWORD)
    assert_not user.authenticate("incorrect password")

    short_password_user = build_user(
      email_address: "short-password@example.test",
      password: "too-short",
      password_confirmation: "too-short"
    )

    assert_not short_password_user.valid?
    assert short_password_user.errors.of_kind?(:password, :too_short)
  end

  test "rejects a case-insensitive duplicate email address in the application" do
    create_user!(email_address: "person@example.test")
    duplicate = build_user(email_address: "  PERSON@EXAMPLE.TEST ")

    assert_not duplicate.valid?
    assert duplicate.errors.of_kind?(:email_address, :taken)
  end

  test "enforces case-insensitive email uniqueness in the database" do
    user = create_user!(email_address: "database-unique@example.test")

    error = assert_raises(ActiveRecord::RecordNotUnique) do
      User.insert_all!([ raw_user_attributes(email_address: user.email_address) ])
    end

    assert_kind_of PG::UniqueViolation, error.cause
  end

  test "database rejects a non-normalized name" do
    user = create_user!(email_address: "database-name-check@example.test")

    error = assert_raises(ActiveRecord::StatementInvalid) do
      User.connection.execute("UPDATE users SET name = ' Padded Name ' WHERE id = #{user.id}")
    end

    assert_kind_of PG::CheckViolation, error.cause
  end

  test "database rejects a non-normalized email address" do
    user = create_user!(email_address: "database-email-check@example.test")

    error = assert_raises(ActiveRecord::StatementInvalid) do
      User.connection.execute("UPDATE users SET email_address = 'UPPERCASE@example.test' WHERE id = #{user.id}")
    end

    assert_kind_of PG::CheckViolation, error.cause
  end

  test "database rejects an empty password digest" do
    error = assert_raises(ActiveRecord::StatementInvalid) do
      User.insert_all!([ raw_user_attributes(password_digest: "") ])
    end

    assert_kind_of PG::CheckViolation, error.cause
  end

  test "database rejects an unsupported system role" do
    error = assert_raises(ActiveRecord::StatementInvalid) do
      User.insert_all!([ raw_user_attributes(system_role: "super_admin") ])
    end

    assert_kind_of PG::CheckViolation, error.cause
  end

  test "password reset token expires" do
    user = create_user!
    token = user.password_reset_token

    assert_equal user, User.find_by_password_reset_token(token)

    travel 15.minutes + 1.second do
      assert_nil User.find_by_password_reset_token(token)
    end
  end

  test "password reset token cannot be reused after the password changes" do
    user = create_user!
    token = user.password_reset_token

    user.update!(password: "a different secure password", password_confirmation: "a different secure password")

    assert_nil User.find_by_password_reset_token(token)
    assert_equal user, user.authenticate("a different secure password")
  end

  test "email verification token expires" do
    user = create_user!
    token = user.email_verification_token

    assert_equal user, User.find_by_email_verification_token(token)

    travel User::EMAIL_VERIFICATION_TOKEN_LIFETIME + 1.second do
      assert_nil User.find_by_email_verification_token(token)
    end
  end

  test "email verification token cannot be reused after verification" do
    user = create_user!
    token = user.email_verification_token

    user.verify_email!

    assert_predicate user, :email_verified?
    assert_nil User.find_by_email_verification_token(token)
  end

  test "changing an email address clears verification and invalidates its token" do
    user = create_user!(email_verified_at: Time.current)
    token = user.email_verification_token

    user.update!(email_address: "changed@example.test")

    assert_nil user.email_verified_at
    assert_nil User.find_by_email_verification_token(token)
  end

  test "authentication eligibility requires verification and an enabled account" do
    user = create_user!

    assert_not user.authentication_allowed?
    assert_predicate user, :password_reset_allowed?
    assert_predicate user, :email_verification_allowed?

    user.verify_email!

    assert_predicate user, :authentication_allowed?
    assert_predicate user, :password_reset_allowed?
    assert_not user.email_verification_allowed?

    user.update!(disabled_at: Time.current)

    assert_predicate user, :disabled?
    assert_not user.authentication_allowed?
    assert_not user.password_reset_allowed?
    assert_not user.email_verification_allowed?
  end

  private
    def build_user(
      name: "Example User",
      email_address: "person@example.test",
      password: PASSWORD,
      password_confirmation: PASSWORD,
      **attributes
    )
      User.new(
        name: name,
        email_address: email_address,
        password: password,
        password_confirmation: password_confirmation,
        **attributes
      )
    end

    def create_user!(**attributes)
      build_user(**attributes).tap(&:save!)
    end

    def raw_user_attributes(**overrides)
      {
        name: "Database User",
        email_address: "database-constraint@example.test",
        password_digest: BCrypt::Password.create(PASSWORD),
        system_role: "user",
        created_at: Time.current,
        updated_at: Time.current
      }.merge(overrides)
    end
end
